package main

import (
	"strings"

	"virelai/vi"
	"virelai/webrender"
	"virelai/webstyle"
)

type formControl struct {
	node, form *webrender.Node
	kind, name string
	value      string
	checked    bool
	disabled   bool
	changed    bool
	options    []string
	labels     []string
	selected   int
	rect       webrender.BoxRect
}

func (a *app) initForms() {
	a.controls, a.focusControl = nil, nil
	a.formOverflow = false
	var walk func(*webrender.Node, *webrender.Node, bool)
	walk = func(n, form *webrender.Node, disabled bool) {
		if n.Tag == "script" || n.Tag == "style" || n.Tag == "template" {
			return
		}
		if n.Tag == "form" {
			form = n
		}
		disabled = disabled || n.HasAttr("disabled")
		if webrender.FormControl(n.Tag) {
			if len(a.controls) >= 64 {
				a.formOverflow = true
				a.diagnostic(webstyle.DiagnosticLimit, "form-control-limit")
				return
			}
			c := &formControl{node: n, form: form, name: n.Attr("name"),
				value: n.Attr("value"), checked: n.HasAttr("checked"), disabled: disabled, changed: true}
			switch n.Tag {
			case "input":
				c.kind = strings.ToLower(n.Attr("type"))
				if c.kind == "" {
					c.kind = "text"
				}
				if c.kind == "checkbox" && !n.HasAttr("value") {
					c.value = "on"
				}
			case "button":
				c.kind = strings.ToLower(n.Attr("type"))
				if c.kind == "" {
					c.kind = "submit"
				}
			case "select":
				c.kind = "select"
				c.selected = -1
				var options func(*webrender.Node, bool)
				options = func(o *webrender.Node, blocked bool) {
					blocked = blocked || o.HasAttr("disabled")
					if o.Tag == "option" && !blocked {
						label := webrender.TextContent(o)
						value := o.Attr("value")
						if !o.HasAttr("value") {
							value = label
						}
						if o.HasAttr("selected") && c.selected < 0 {
							c.selected = len(c.options)
						}
						c.options, c.labels = append(c.options, value), append(c.labels, label)
						return
					}
					for _, child := range o.Children {
						options(child, blocked)
					}
				}
				options(n, disabled)
				if len(c.options) > 0 {
					if c.selected < 0 {
						c.selected = 0
					}
					c.value = c.options[c.selected]
				}
			default:
				c.kind = "unsupported"
			}
			a.controls = append(a.controls, c)
			return
		}
		for _, child := range n.Children {
			walk(child, form, disabled)
		}
	}
	walk(a.doc.Root, nil, false)
	if a.lay != nil {
		for _, c := range a.controls {
			for _, it := range a.lay.Items {
				if it.Kind == webrender.ItemRect && it.Box != nil && it.Box.Node == c.node {
					c.rect = webrender.BoxRect{X: it.X, Y: it.Y, W: it.W, H: it.H}
					break
				}
			}
		}
	}
}

func (c *formControl) supported() bool {
	switch c.kind {
	case "text", "search", "hidden", "checkbox", "submit":
		return true
	case "select":
		return !c.node.HasAttr("multiple")
	}
	return false
}

func formEncode(value string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9',
			c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		case c == ' ':
			b.WriteByte('+')
		default:
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		}
	}
	return b.String()
}

func (a *app) formTarget(form, activated *webrender.Node) (string, string) {
	if a.formOverflow {
		return "", "form-control-limit"
	}
	method := strings.ToLower(strings.TrimSpace(form.Attr("method")))
	if method != "" && method != "get" {
		return "", "form-method-unsupported"
	}
	var pairs []string
	for _, c := range a.controls {
		if c.form != form || c.disabled {
			continue
		}
		if !c.supported() {
			return "", "form-control-unsupported"
		}
		if len(c.name) > 256 || len(c.value) > 256 {
			return "", "form-control-limit"
		}
		if c.name == "" || c.kind == "checkbox" && !c.checked ||
			c.kind == "submit" && c.node != activated {
			continue
		}
		pairs = append(pairs, formEncode(c.name)+"="+formEncode(c.value))
	}
	action := form.Attr("action")
	if action == "" {
		action = a.target
	}
	target := strings.SplitN(relativeTo(a.target, action), "#", 2)[0]
	target = strings.SplitN(target, "?", 2)[0] + "?" + strings.Join(pairs, "&")
	if len(target) > maxGetURLBytes {
		return "", "form-url-limit"
	}
	return target, ""
}

func (a *app) submitForm(form, activated *webrender.Node) {
	if form == nil {
		return
	}
	target, kind := a.formTarget(form, activated)
	if kind != "" {
		a.finishError(kind, a.target, a.target)
		return
	}
	vi.ConsoleLine("web: form-get")
	a.navigate(target, a.target)
}

func (a *app) focusNextControl(reverse bool) {
	if len(a.controls) == 0 {
		return
	}
	at := -1
	for i, c := range a.controls {
		if c == a.focusControl {
			at = i
			break
		}
	}
	step := 1
	if reverse {
		step = -1
		if at < 0 {
			at = 0
		}
	}
	for i := 0; i < len(a.controls); i++ {
		at = (at + step + len(a.controls)) % len(a.controls)
		c := a.controls[at]
		if !c.disabled && c.kind != "hidden" && c.rect.W > 0 && c.rect.H > 0 {
			a.focusControl = c
			a.controlEdit.reset(c.value, 256)
			a.dirty = true
			return
		}
	}
}

func (a *app) clickControl(x, y int) bool {
	for _, c := range a.controls {
		if c.disabled || !inRect(x, y, c.rect.X, c.rect.Y, c.rect.W, c.rect.H) {
			continue
		}
		a.focusControl = c
		a.controlEdit.reset(c.value, 256)
		switch c.kind {
		case "checkbox":
			c.checked = !c.checked
			c.changed = true
		case "select":
			if len(c.options) > 0 {
				c.selected = (c.selected + 1) % len(c.options)
				c.value = c.options[c.selected]
				c.changed = true
			}
		case "submit":
			a.submitForm(c.form, c.node)
		}
		a.dirty = true
		return true
	}
	a.focusControl = nil
	return false
}

func (a *app) controlKey(ev vi.Event) bool {
	c := a.focusControl
	if c == nil {
		return false
	}
	switch ev.Arg0 {
	case keyEscape:
		a.focusControl = nil
	case 0x2b:
		a.focusNextControl(ev.Flags&vi.ModShift != 0)
	case 0x28:
		a.submitForm(c.form, c.node)
	default:
		switch c.kind {
		case "text", "search":
			if a.controlEdit.key(ev.Arg0, ev.Arg1, ev.Flags) {
				c.value = a.controlEdit.text
				c.changed = true
			}
		case "checkbox":
			if ev.Arg0 == 0x2c {
				c.checked = !c.checked
				c.changed = true
			}
		case "select":
			if (ev.Arg0 == keyUp || ev.Arg0 == keyDown) && len(c.options) > 0 {
				step := 1
				if ev.Arg0 == keyUp {
					step = -1
				}
				c.selected = (c.selected + step + len(c.options)) % len(c.options)
				c.value = c.options[c.selected]
				c.changed = true
			}
		}
	}
	a.dirty = true
	return true
}

func (a *app) updateControlPaint() {
	if a.lay == nil {
		return
	}
	for i := range a.lay.Items {
		it := &a.lay.Items[i]
		if it.Kind != webrender.ItemText || it.Box == nil {
			continue
		}
		for _, c := range a.controls {
			if c == nil || c.node != it.Box.Node || !c.changed {
				continue
			}
			switch c.kind {
			case "text", "search":
				it.Text = c.value
			case "checkbox":
				if c.checked {
					it.Text = "[x]"
				} else {
					it.Text = "[ ]"
				}
			case "select":
				if len(c.labels) > 0 {
					it.Text = c.labels[c.selected]
				}
			}
			st := webrender.Style{Size: it.Size, Mono: it.Mono, Serif: it.Serif, Bold: it.Bold, Italic: it.Italic,
				Color: it.Color, FontPx: it.FontPx, LineHeightPx: it.LineHeightPx}
			engine := a.lay.Text
			if engine == nil {
				engine = webrender.Bitmap{}
			}
			width := max(0, c.rect.X+c.rect.W-4-it.X)
			if engine.Measure(it.Text, st) > width {
				runes := []rune(it.Text)
				lo, hi := 0, len(runes)
				for lo < hi {
					mid := (lo + hi + 1) / 2
					if engine.Measure(string(runes[:mid]), st) <= width {
						lo = mid
					} else {
						hi = mid - 1
					}
				}
				it.Text = string(runes[:lo])
			}
		}
	}
}
