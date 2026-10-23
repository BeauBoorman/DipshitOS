#!/usr/bin/env python3
"""Build the M99m (#2190) coverage faces for image/fonts/.

Pipeline per face: fetch a PINNED variable glyf TTF from the google/fonts
repo (commit-pinned URL + SHA-256 of the source bytes), instance it to a
static Regular with fontTools' varLib instancer, then pyftsubset it to the
ranges this card scoped. Output SHA-256s are printed for the fonts.txt
comments and the PR size table.

Why instancing+subsetting at all: the canonical Noto CJK releases are
CFF-based OpenType and NEITHER of the guest's engines parses CFF
(virelai/ttf refuses 'OTTO', Zig font_ttf is glyf-only). Google Fonts'
NotoSansJP[wght].ttf is a glyf variable font, so a wght=400 static
instance plus a bounded subset lands under the 512 KiB per-face read cap
(user/go/browser/text.go maxFontBytes).

Toolchain: Python 3 + fontTools (MIT license).
  pip install 'fontTools[ufo]'   # any 4.x; produced with 4.65.0

Usage:
  python3 tools/fonts/build-faces.py --src-dir DIR   # reads pinned sources from DIR
  python3 tools/fonts/build-faces.py --fetch DIR     # downloads + verifies into DIR first

Outputs (written to image/fonts/):
  NotoSerif-Regular.ttf    -> staged share name NOTOSERF.TTF (role=serif, ui tail)
  NotoSansJP-Regular.ttf   -> staged share name NOTOCJK.TTF  (role=symbol tail)
  NotoSansHebrew-Regular.ttf -> staged NOTOHEB.TTF (role=ui cascade tail; M178a
                             #3144 — bidi lives in user/go/ttf/bidi.go)
"""

import hashlib
import os
import sys
import urllib.request

# --- Pinned sources (google/fonts repo at a fixed commit) --------------------
# Fetching the same URL must yield the same bytes; the SHA-256 check is the
# pin. OFL 1.1 both; Noto Serif declares no Reserved Font Name, Noto Sans JP
# reserves only 'Source' — the modified faces keep their Noto names lawfully.
SOURCES = {
    "NotoSerif-var.ttf": {
        "url": "https://raw.githubusercontent.com/google/fonts/"
               "8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/"
               "ofl/notoserif/NotoSerif%5Bwdth%2Cwght%5D.ttf",
        "sha256": "4d8e6761424656867019081a1a01336f3cb086982682698714054fc33f782713",
        "family": "Noto Serif 2.015", "license": "OFL-1.1",
    },
    "NotoSansJP-var.ttf": {
        "url": "https://raw.githubusercontent.com/google/fonts/"
               "66a36c8c94b1a5d992ee4e7f392fccfe4945767c/"
               "ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf",
        "sha256": "c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f",
        "family": "Noto Sans JP 2.004", "license": "OFL-1.1",
    },
    # M178a (#3144): the Hebrew face for the bidi arc. Same google/fonts
    # commit pin as NotoSerif; OFL 1.1, no Reserved Font Name (METADATA.pb
    # declares designer "Google", the OFL header names The Noto Project
    # Authors only).
    "NotoSansHebrew-var.ttf": {
        "url": "https://raw.githubusercontent.com/google/fonts/"
               "8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/"
               "ofl/notosanshebrew/NotoSansHebrew%5Bwdth%2Cwght%5D.ttf",
        "sha256": "7ef36a2c3593758cdb622e1bdef4f84523e92fbc3ccc667438dd80ff54c2de88",
        "family": "Noto Sans Hebrew 3.001", "license": "OFL-1.1",
    },
}

# Non-Han coverage the CJK face keeps: printable Latin, Latin-1, CJK symbols
# and punctuation, hiragana, katakana, fullwidth forms, halfwidth katakana,
# arrows, math operators, box drawing and misc symbols.
CJK_BLOCKS = [
    (0x20, 0x7E),    # basic Latin
    (0xA0, 0xFF),    # Latin-1 supplement
    (0x3000, 0x303F),  # CJK symbols and punctuation
    (0x3040, 0x309F),  # hiragana
    (0x30A0, 0x30FF),  # katakana
    (0xFF01, 0xFF60),  # fullwidth forms
    (0xFF61, 0xFF9F),  # halfwidth katakana
    (0x2190, 0x21FF),  # arrows
    (0x2200, 0x22FF),  # mathematical operators
    (0x2500, 0x257F),  # box drawing
    (0x2600, 0x26FF),  # miscellaneous symbols
]

# The Han repertoire: the 1,026 kyōiku kanji (the taught-in-elementary subset
# of the 2010 jōyō list, grades 1–6), embedded so the build never re-derives
# it from a drifting source. Measured fit: ~400 KiB with the blocks above;
# the full jōyō 2,136 would blow the 512 KiB cap (the card measured ~1–1.5 MB).
KYOIKU = (
    "一二三四五六七八九十百千上下左右中大小月日年早木林山川土空田天生花草虫犬人名女男子目耳口手足見音力気円入出立休先夕本文字学校村町"
    "森正水火玉王石竹糸貝車金雨赤青白数多少万半形太細広長点丸交光角計直線矢弱強高同親母父姉兄弟妹自友体毛頭顔首心時曜朝昼夜分週春夏秋"
    "冬今新古間方北南東西遠近前後内外場地国園谷野原里市京風雪雲池海岩星室戸家寺通門道話言答声聞語読書記紙画絵図工教晴思考知才理算作元"
    "食肉馬牛魚鳥羽鳴麦米茶色黄黒来行帰歩走止活店買売午汽弓回会組船明社切電毎合当台楽公引科歌刀番用何丁世両主乗予事仕他代住使係倍全具"
    "写列助勉動勝化区医去反取受号向君味命和品員商問坂央始委守安定実客宮宿寒対局屋岸島州帳平幸度庫庭式役待急息悪悲想意感所打投拾持指放"
    "整旅族昔昭暑暗曲有服期板柱根植業様横橋次歯死氷決油波注泳洋流消深温港湖湯漢炭物球由申界畑病発登皮皿相県真着短研礼神祭福秒究章童笛"
    "第筆等箱級終緑練羊美習者育苦荷落葉薬血表詩調談豆負起路身転軽農返追送速進遊運部都配酒重鉄銀開院陽階集面題飲館駅鼻不争井付令以仲伝"
    "位低佐例便信倉候借健側働億兆児共兵典冷初別利刷副功加努労勇包卒協単博印参司各周唱器固城埼塩変夫失奈好媛季孫完官害富察岐岡崎巣差希"
    "席帯底府康建径徒徳必念愛成戦折挙改敗散料旗昨景最望未末札材束松果栃栄案梅梨械極標機欠残氏民求沖治法泣浅浴清満滋漁潟灯無然焼照熊熱"
    "牧特産的省祝票種積競笑管節約結給続縄置老臣良芸芽英茨菜街衣要覚観訓試説課議貨賀軍輪辞辺連達選郡群量録鏡関阜阪陸隊静順願類飛飯養香"
    "験鹿久仏仮件任似余価保修個停備像再刊判制則効務勢厚句可史告喜営因団囲圧在均型基堂報境墓増士夢妻婦容寄導居属布師常幹序弁張往得復志"
    "応快性情態慣技招授採接提損支政故救断旧易暴条枝査格桜検構武歴殺毒比永河液混減測準演潔災燃版犯状独率現留略益眼破確示祖禁移程税築粉"
    "精紀素経統絶綿総編績織罪義耕職肥能脈興舎航術衛製複規解設許証評講謝識護豊象財貧責貯貸費貿資賛賞質輸述迷逆造過適酸鉱銅防限険際雑非"
    "領額飼並乱乳亡仁供俳俵値傷優党冊処券刻割創劇勤危卵厳収后否吸呼善困垂域奏奮姿存孝宅宇宗宙宝宣密寸専射将尊就尺届展層己巻幕干幼庁座"
    "延律従忘忠恩憲我批承担拝拡捨探推揮操敬敵映晩暖暮朗机枚染株棒模権樹欲段沿泉洗派済源潮激灰熟片班異疑痛皇盛盟看砂磁私秘穀穴窓筋策簡"
    "糖系紅納純絹縦縮署翌聖肺胃背胸脳腸腹臓臨至舌若著蒸蔵蚕衆裁装裏補視覧討訪訳詞誌認誕誠誤論諸警貴賃退遺郵郷針銭鋼閉閣降陛除障難革頂"
    "預骨"
)


# The Hebrew repertoire (M178a): the whole Hebrew block — letters, niqqud
# (the combining points W1 attaches to the preceding letter at bidi-resolve
# time; they paint at their default advance, no mark positioning) — and the
# Hebrew Alphabetic Presentation Forms. Latin coverage stays with the ui
# primaries: the registry cascade hands Latin runes to Inter first, so this
# face keeps only what Inter lacks.
HEBREW_BLOCKS = [
    (0x0590, 0x05FF),  # Hebrew
    (0xFB1D, 0xFB4F),  # Hebrew presentation forms
]


def fetch_sources(src_dir):
    """Download each pinned source into src_dir, verifying SHA-256."""
    os.makedirs(src_dir, exist_ok=True)
    for name, spec in SOURCES.items():
        dst = os.path.join(src_dir, name)
        if not os.path.exists(dst):
            print("fetch:", spec["url"])
            data = urllib.request.urlopen(spec["url"]).read()
            open(dst, "wb").write(data)
        got = hashlib.sha256(open(dst, "rb").read()).hexdigest()
        if got != spec["sha256"]:
            sys.exit("FAIL: %s sha256 %s != pinned %s" % (name, got, spec["sha256"]))
        print("ok: %s sha256=%s (%s, %s)" % (name, got[:16], spec["family"], spec["license"]))


def build(src_dir, out_dir):
    from fontTools import subset
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    def instance(name, axes):
        f = TTFont(os.path.join(src_dir, name))
        instantiateVariableFont(f, axes, inplace=True, updateFontNames=True)
        return f

    def prune(font, keep):
        opts = subset.Options()
        opts.name_IDs = ["*"]
        opts.layout_features = ["liga", "kern", "calt"]
        opts.notdef_outline = True
        opts.recalc_bounds = True
        opts.drop_tables += ["BASE", "GDEF", "HVAR", "STAT", "avar",
                             "gasp", "vhea", "vmtx", "DSIG"]
        opts.hinting = False  # bytecode hinting is a named mountain — drop it
        ss = subset.Subsetter(options=opts)
        ss.populate(unicodes=keep)
        ss.subset(font)
        return font

    # Serif: full coverage, instanced at Regular; only bytecode stripped.
    serif = instance("NotoSerif-var.ttf", {"wght": 400, "wdth": 100})
    serif = prune(serif, set(serif.getBestCmap().keys()))
    out = os.path.join(out_dir, "NotoSerif-Regular.ttf")
    serif.save(out)
    report(out)

    # CJK: instanced at Regular, then the bounded subset above.
    cjk = instance("NotoSansJP-var.ttf", {"wght": 400})
    uni = set(ord(c) for c in KYOIKU)
    for lo, hi in CJK_BLOCKS:
        uni |= set(range(lo, hi + 1))
    cjk = prune(cjk, uni)
    out = os.path.join(out_dir, "NotoSansJP-Regular.ttf")
    cjk.save(out)
    report(out)

    # Hebrew (M178a): instanced at Regular weight and nominal width, then the
    # bounded Hebrew subset above.
    hebrew = instance("NotoSansHebrew-var.ttf", {"wght": 400, "wdth": 100})
    uni = set()
    for lo, hi in HEBREW_BLOCKS:
        uni |= set(range(lo, hi + 1))
    hebrew = prune(hebrew, uni)
    out = os.path.join(out_dir, "NotoSansHebrew-Regular.ttf")
    hebrew.save(out)
    report(out)


def report(path):
    data = open(path, "rb").read()
    cap = 512 * 1024
    status = "ok" if len(data) < cap else "OVER THE 512 KiB CAP"
    print("built %s: %d bytes sha256=%s  %s"
          % (path, len(data), hashlib.sha256(data).hexdigest(), status))
    if len(data) >= cap:
        sys.exit(1)


def main():
    root = os.path.join(os.path.dirname(__file__), "..", "..")
    out_dir = os.path.join(root, "image", "fonts")
    args = sys.argv[1:]
    if args[:1] == ["--fetch"]:
        if len(args) != 2:
            sys.exit("usage: --fetch DIR")
        fetch_sources(args[1])
        src_dir = args[1]
    elif args[:1] == ["--src-dir"] and len(args) == 2:
        src_dir = args[1]
        fetch_sources(src_dir)  # verify-only: files must already exist
    else:
        sys.exit("usage: build-faces.py --fetch DIR | --src-dir DIR")
    build(src_dir, out_dir)


if __name__ == "__main__":
    main()
