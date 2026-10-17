#!/usr/bin/env python3
#
# convert-smollm2.py -- the M111c (#2410) host-side VIW converter: turns the
# owner-approved upstream checkpoint (HuggingFaceTB/SmolLM2-135M-Instruct,
# Apache-2.0) into the SMOLLM2.VIW container the guest GOINFER.ELF streams.
#
# Python stdlib only -- no numpy, no safetensors/GGUF/third-party loaders,
# per the card's converter constraint. Deterministic: same upstream bytes in,
# same VIW bytes out (fixed header order, fixed directory order).
#
#   python3 tools/goinfer/convert-smollm2.py \
#       --safetensors artifacts/goinfer/upstream/model.safetensors \
#       --tokenizer  artifacts/goinfer/upstream/tokenizer.json \
#       --out        artifacts/goinfer/SMOLLM2.VIW
#
# The upstream sha256 pins are the owner-approved values from #2410; the
# script refuses any other bytes. The produced file's own sha256 is printed
# and pinned in tools/gate/specs/live-gpu3d.spec (the staged digest the legs
# verify); it also lands in the app's per-run licence receipt. The file is
# staged on the gate share only -- never in git, never in the boot image
# (the clawback condition on #2410).

import argparse
import hashlib
import json
import math
import os
import struct
import sys
from array import array

# --- owner-approved upstream pins (issue #2410) -------------------------------

MODEL_ID = "HuggingFaceTB/SmolLM2-135M-Instruct"
MODEL_SOURCE = "https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct"
MODEL_LICENSE = "Apache-2.0"
UPSTREAM_SHA256 = "5af571cbf074e6d21a03528d2330792e532ca608f24ac70a143f6b369968ab8c"
UPSTREAM_BYTES = 269060552
TOKENIZER_SHA256 = "9ca9acddb6525a194ec8ac7a87f24fbba7232a9a15ffa1af0c1224fcd888e47c"

# --- the model's shape (config.json, verified against the header below) ------

DIM, HIDDEN, LAYERS = 576, 1536, 30
HEADS, KV_HEADS, VOCAB = 9, 3, 49152
HEAD_DIM = DIM // HEADS                      # 64
QKV_DIM = (HEADS + 2 * KV_HEADS) * HEAD_DIM  # 960
SEQ_CAP = 192                    # the card's runtime context bound
ROPE_THETA, RMS_EPS = 100000.0, 1e-5
BOS, EOS = 1, 2                  # ChatML im_start/im_end token ids
WEIGHT_GROUP = 128               # u4asym group for device tensors
EMBED_GROUP = 64                 # must divide DIM (lm_head row slicing)

# VIW container constants -- byte-twins of user/go/goinfer/viw.go.
VIW_MAGIC, VIW_PREFIX_LEN, VIW_DIR_ENT_LEN = 0x31574956, 64, 96
FMT_Q8SYM, FMT_U4ASYM, FMT_F16, FMT_F32 = 1, 2, 3, 4
TOK_KIND_BPE = 2


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def read_safetensors_index(path):
    with open(path, "rb") as f:
        (hlen,) = struct.unpack("<Q", f.read(8))
        header = json.loads(f.read(hlen))
        data_off = 8 + hlen
    index = {}
    for name, rec in header.items():
        if name == "__metadata__":
            continue
        if rec["dtype"] != "BF16":
            sys.exit("convert: %s dtype %s (want BF16)" % (name, rec["dtype"]))
        index[name] = (rec["shape"], rec["data_offsets"])
    return index, data_off


def bf16_span(f, off, n):
    """Read n bf16 elements at absolute span off; return f32 LE bytes.

    bf16 is the top half of f32: each element's 2 bytes become the high
    bytes of a 4-byte little-endian word -- extended-slice assignment, no
    per-element Python work."""
    f.seek(off)
    src = f.read(n * 2)
    if len(src) != n * 2:
        sys.exit("convert: short tensor read (%d of %d)" % (len(src), n * 2))
    out = bytearray(n * 4)
    out[2::4] = src[0::2]
    out[3::4] = src[1::2]
    return out


def round_half_away(x):
    return math.floor(x + 0.5) if x >= 0 else math.ceil(x - 0.5)


def quant_u4asym(vals, group):
    """Pack vals into the DEQUANT fmt-2 payload -- the byte-twin of
    quantU4Asym in user/go/goinfer/viw.go: [packed nibbles, low first]
    [groups x f32 scales][groups x f32 zeros], out = (q - z) * s."""
    n = len(vals)
    groups = (n + group - 1) // group
    packed = bytearray((n + 1) // 2)
    scales = bytearray(groups * 4)
    zeros = bytearray(groups * 4)
    for g in range(groups):
        lo, hi = g * group, min((g + 1) * group, n)
        seg = vals[lo:hi]
        mn, mx = min(seg), max(seg)
        s = (mx - mn) / 15.0
        if s == 0:
            s, z = 1.0, 0.0
        else:
            z = round_half_away(-mn / s)
            z = 0.0 if z < 0 else (15.0 if z > 15 else z)
        struct.pack_into("<f", scales, g * 4, s)
        struct.pack_into("<f", zeros, g * 4, z)
        for i in range(lo, hi):
            q = int(round_half_away(vals[i] / s + z))
            q = 0 if q < 0 else (15 if q > 15 else q)
            if i & 1 == 0:
                packed[i // 2] |= q
            else:
                packed[i // 2] |= q << 4
    return bytes(packed) + bytes(scales) + bytes(zeros)


# --- VIW emit (byte-twin of viwWrite.marshal) ---------------------------------


def fmt_g(v):
    """strconv.FormatFloat(v,'g',-1,64): integral values print as integers."""
    return repr(int(v)) if v == int(v) else repr(v)


def emit_header(fields):
    return "".join("%s %s\n" % (k, v) for k, v in fields).encode()


def emit_dir_ent(name, fmtb, group, dims, off, paylen):
    e = bytearray(VIW_DIR_ENT_LEN)
    nb = name.encode()
    if len(nb) > 32:
        sys.exit("convert: tensor name too long %r" % name)
    e[: len(nb)] = nb
    e[32] = fmtb
    e[33] = 2 if dims[1] else 1
    e[34] = group
    struct.pack_into("<II", e, 36, dims[0], dims[1])
    struct.pack_into("<QQ", e, 56, off, paylen)
    return bytes(e)


def emit_tok_bpe(vocab_list, merges, bos, eos):
    out = bytearray()
    out += struct.pack("<IIII", TOK_KIND_BPE, bos, eos, len(vocab_list))
    for s in vocab_list:
        b = s.encode("utf-8")
        out += struct.pack("<H", len(b)) + b
    out += struct.pack("<I", len(merges))
    for a, b in merges:
        out += struct.pack("<II", a, b)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(
        description="safetensors+tokenizer.json -> SMOLLM2.VIW (stdlib only)")
    ap.add_argument("--safetensors", required=True)
    ap.add_argument("--tokenizer", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    # The pins are the contract: refuse anything but the approved bytes.
    usha = sha256_file(a.safetensors)
    if usha != UPSTREAM_SHA256:
        sys.exit("convert: safetensors sha256 %s != approved %s"
                 % (usha, UPSTREAM_SHA256))
    tsha = sha256_file(a.tokenizer)
    if tsha != TOKENIZER_SHA256:
        sys.exit("convert: tokenizer.json sha256 %s != approved %s"
                 % (tsha, TOKENIZER_SHA256))
    if os.path.getsize(a.safetensors) != UPSTREAM_BYTES:
        sys.exit("convert: safetensors size != approved %d" % UPSTREAM_BYTES)

    index, data_off = read_safetensors_index(a.safetensors)

    def span(name, want_shape):
        shape, (lo, hi) = index[name]
        if shape != want_shape:
            sys.exit("convert: %s shape %s want %s" % (name, shape, want_shape))
        n = 1
        for d in shape:
            n *= d
        if hi - lo != n * 2:
            sys.exit("convert: %s span %d want %d" % (name, hi - lo, n * 2))
        return data_off + lo, n

    # --- tokenizer blob -------------------------------------------------------
    tj = json.load(open(a.tokenizer))
    model = tj["model"]
    if model["type"] != "BPE":
        sys.exit("convert: tokenizer type %r" % model["type"])
    vocab = model["vocab"]
    if len(vocab) != VOCAB:
        sys.exit("convert: vocab %d want %d" % (len(vocab), VOCAB))
    vocab_list = [""] * VOCAB
    for s, i in vocab.items():
        vocab_list[i] = s
    merges = []
    for m in model["merges"]:
        pa, pb = m.split(" ")
        merges.append((vocab[pa], vocab[pb]))
    tok = emit_tok_bpe(vocab_list, merges, BOS, EOS)

    # --- header ---------------------------------------------------------------
    fields = [
        ("arch", "llama"), ("dim", DIM), ("hidden", HIDDEN),
        ("layers", LAYERS), ("heads", HEADS), ("kv_heads", KV_HEADS),
        ("vocab", VOCAB), ("seq_cap", SEQ_CAP), ("rope", "half"),
        ("rope_theta", fmt_g(ROPE_THETA)), ("rms_eps", fmt_g(RMS_EPS)),
        ("tie", "1"), ("bos", BOS), ("eos", EOS),
        ("m_id", MODEL_ID), ("m_license", MODEL_LICENSE),
        ("m_source", MODEL_SOURCE), ("m_usha", UPSTREAM_SHA256),
        ("m_ubytes", UPSTREAM_BYTES), ("m_tsha", TOKENIZER_SHA256),
    ]
    hb = emit_header(fields)

    # --- tensors, in VIW directory order --------------------------------------
    # (name, fmt, group, dims, source spans): fused tensors concatenate their
    # source spans' f32 values before quantizing -- wqkv is [q|k|v] rows,
    # w13 is [gate|up] rows, the same order the engine slices.
    plan = [("embed", FMT_U4ASYM, EMBED_GROUP, (VOCAB, DIM),
             [("model.embed_tokens.weight", [VOCAB, DIM])]),
            ("final_norm", FMT_F32, 0, (DIM, 0),
             [("model.norm.weight", [DIM])])]
    for l in range(LAYERS):
        p = "model.layers.%d." % l
        lp = "l%d." % l
        plan += [
            (lp + "attn_norm", FMT_F32, 0, (DIM, 0),
             [(p + "input_layernorm.weight", [DIM])]),
            (lp + "wqkv", FMT_U4ASYM, WEIGHT_GROUP, (QKV_DIM, DIM),
             [(p + "self_attn.q_proj.weight", [HEADS * HEAD_DIM, DIM]),
              (p + "self_attn.k_proj.weight", [KV_HEADS * HEAD_DIM, DIM]),
              (p + "self_attn.v_proj.weight", [KV_HEADS * HEAD_DIM, DIM])]),
            (lp + "wo", FMT_U4ASYM, WEIGHT_GROUP, (DIM, HEADS * HEAD_DIM),
             [(p + "self_attn.o_proj.weight", [DIM, HEADS * HEAD_DIM])]),
            (lp + "ffn_norm", FMT_F32, 0, (DIM, 0),
             [(p + "post_attention_layernorm.weight", [DIM])]),
            (lp + "w13", FMT_U4ASYM, WEIGHT_GROUP, (2 * HIDDEN, DIM),
             [(p + "mlp.gate_proj.weight", [HIDDEN, DIM]),
              (p + "mlp.up_proj.weight", [HIDDEN, DIM])]),
            (lp + "w2", FMT_U4ASYM, WEIGHT_GROUP, (DIM, HIDDEN),
             [(p + "mlp.down_proj.weight", [DIM, HIDDEN])]),
        ]

    payloads = []
    with open(a.safetensors, "rb") as f:
        for name, fmtb, group, dims, srcs in plan:
            f32 = bytearray()
            for src, shape in srcs:
                off, n = span(src, shape)
                f32 += bf16_span(f, off, n)
            if fmtb == FMT_U4ASYM:
                vals = array("f")
                vals.frombytes(bytes(f32))
                pay = quant_u4asym(vals, group)
            elif fmtb == FMT_F32:
                pay = bytes(f32)
            else:
                sys.exit("convert: unhandled fmt %d" % fmtb)
            want = dims[0] * (dims[1] or 1)
            if fmtb == FMT_U4ASYM:
                groups = (want + group - 1) // group
                exp = (want + 1) // 2 + groups * 8
            else:
                exp = want * 4
            if len(pay) != exp:
                sys.exit("convert: %s payload %d want %d"
                         % (name, len(pay), exp))
            payloads.append(pay)
            print("convert: %-16s fmt=%d dims=%s -> %d bytes"
                  % (name, fmtb, dims, len(pay)), file=sys.stderr)

    # --- marshal --------------------------------------------------------------
    dir_len = len(plan) * VIW_DIR_ENT_LEN
    off = VIW_PREFIX_LEN + len(hb) + len(tok) + dir_len
    out = bytearray(VIW_PREFIX_LEN)
    struct.pack_into("<IIIII", out, 0, VIW_MAGIC, len(hb), len(tok), len(plan), 0)
    out += hb
    out += tok
    for (name, fmtb, group, dims, _), pay in zip(plan, payloads):
        out += emit_dir_ent(name, fmtb, group, dims, off, len(pay))
        off += len(pay)
    for pay in payloads:
        out += pay

    tmp = a.out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(out)
    os.replace(tmp, a.out)
    digest = sha256_file(a.out)
    print("convert: wrote %s (%d bytes)" % (a.out, len(out)))
    print("convert: staged sha256 %s" % digest)


if __name__ == "__main__":
    main()
