package main

// account.go — the GOMAIL account settings file: a small key=value codec
// (the SETTINGS.TXT grammar, not the schema: an app file, not the kernel
// table). The card's "configure account via settings-file" half — GOVAULT
// exists but its passphrase-locked entries have no headless unlock path;
// a plain file is the mechanism that exists for a console tool.
//
// Keys: host, user, pass, from, sni, imap_port, smtp_port, tls (on|off),
// plain (on|off — the stored plaintext-consent answer), max_headers.
// Argv overrides file values. A corrupt file is a named refusal, never a
// half-parsed account; a missing file is fine — argv must then carry the
// account whole.

import (
	"strings"

	"virelai/vi"
)

// DefaultAccountPath is where the app looks when --account is absent.
const DefaultAccountPath = "/host/GOMAIL.TXT"

const (
	accountMaxBytes = 4096
	accountMaxRows  = 32
	accountMaxKey   = 16
	accountMaxVal   = 128
)

// Config is the resolved account — argv merged over the file.
type Config struct {
	Host string
	User string
	Pass string
	From string // envelope+From: address; empty falls back to User

	// TLS selects tls.Dial (993/465 by convention). Plaintext runs ONLY
	// under AllowPlain — the stored consent answer; dialOne refuses
	// otherwise.
	TLS        bool
	ServerName string // SNI/verify name; empty takes Host
	AllowPlain bool

	IMAPPort uint16 // 0 = transport default
	SMTPPort uint16 // 0 = transport default

	MaxHeaders int // header list bound; 0 = headerMaxDefault
}

const (
	headerMaxDefault = 20
	headerMaxBound   = 200
)

// imapPort resolves the port in force for the IMAP leg.
func (c Config) imapPort() uint16 {
	if c.IMAPPort != 0 {
		return c.IMAPPort
	}
	if c.TLS {
		return 993
	}
	return 143
}

// smtpPort resolves the port in force for the submit leg.
func (c Config) smtpPort() uint16 {
	if c.SMTPPort != 0 {
		return c.SMTPPort
	}
	if c.TLS {
		return 465
	}
	return 587
}

// fromAddr resolves the envelope sender.
func (c Config) fromAddr() string {
	if c.From != "" {
		return c.From
	}
	return c.User
}

// accountApply decodes the file body into cfg. ok=false is the
// named-refusal verdict; the caller reports 'gomail: account bad'.
func (cfg *Config) accountApply(body []byte) bool {
	rows := 0
	for _, raw := range strings.Split(string(body), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		rows++
		if rows > accountMaxRows {
			return false
		}
		k := strings.IndexByte(line, '=')
		if k <= 0 || k > accountMaxKey {
			return false
		}
		key, val := strings.TrimSpace(line[:k]), strings.TrimSpace(line[k+1:])
		if key == "" || len(val) > accountMaxVal {
			return false
		}
		switch key {
		case "host":
			cfg.Host = val
		case "user":
			cfg.User = val
		case "pass":
			cfg.Pass = val
		case "from":
			cfg.From = val
		case "sni":
			cfg.ServerName = val
		case "imap_port":
			n, ok := parseUint(val)
			if !ok || n <= 0 || n > 65535 {
				return false
			}
			cfg.IMAPPort = uint16(n)
		case "smtp_port":
			n, ok := parseUint(val)
			if !ok || n <= 0 || n > 65535 {
				return false
			}
			cfg.SMTPPort = uint16(n)
		case "tls":
			on, ok := onOff(val)
			if !ok {
				return false
			}
			cfg.TLS = on
		case "plain":
			on, ok := onOff(val)
			if !ok {
				return false
			}
			cfg.AllowPlain = on
		case "max_headers":
			n, ok := parseUint(val)
			if !ok || n <= 0 || n > headerMaxBound {
				return false
			}
			cfg.MaxHeaders = int(n)
		default:
			// An unknown key is a named refusal, not a silent drop: a
			// mistyped 'pas=' would otherwise leave the account silently
			// unauthenticated.
			return false
		}
	}
	return true
}

// loadAccount reads the settings file into cfg. Missing file: no-op, ok.
// Corrupt file or unreadable share: false — the caller prints the named
// refusal and exits.
func (cfg *Config) loadAccount(path string) (loaded bool, ok bool) {
	body, rc := vi.ReadFileAll(path, accountMaxBytes)
	if rc < 0 {
		return false, true // absent is not corrupt
	}
	if !cfg.accountApply(body) {
		return false, false
	}
	return true, true
}

func onOff(v string) (bool, bool) {
	switch v {
	case "on", "yes", "true", "1":
		return true, true
	case "off", "no", "false", "0":
		return false, true
	}
	return false, false
}
