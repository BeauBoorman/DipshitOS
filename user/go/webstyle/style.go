// Package webstyle is the frozen, type-only M93 pipeline contract.
// ADR 0028 Amendment D defines resolution, bounds and degradation.
// It imports nothing. Changing it after M93a merges requires owner approval.
package webstyle

// Length is an integral CSS px or percent value, or an initial/auto sentinel.
// Percent is a whole percentage of the reference size: Value=25 means 25%.
// The zero value is initial, not an explicit auto or zero-pixel declaration.
type Length struct {
	Kind  LengthKind
	Value int32
}

type LengthKind uint8

const (
	LengthInitial LengthKind = iota
	LengthAuto
	LengthPx
	LengthPercent
	// Font-relative lengths (M99p #2193), declared on font-size only and
	// resolved to LengthPx by the cascade against the parent's (em) or the
	// root's (rem) computed size. Value is hundredths of the unit:
	// LengthEm{Value:150} is 1.5em.
	LengthEm
	LengthRem
	// The relative keywords smaller/larger: one step off the CSS
	// absolute-size ladder from the parent's computed size. Value is unused.
	LengthFontSmaller
	LengthFontLarger
)

// Edges are physical, not logical, sides in top/right/bottom/left order.
type Edges struct {
	Top, Right, Bottom, Left Length
}

// ColorRGBA stores straight-alpha 0xAARRGGBB, including transparent=0.
// ColorInitial resolves by property: black foreground, transparent background,
// current foreground for a border. ColorCurrent uses the computed foreground.
type Color struct {
	Kind ColorKind
	RGBA uint32
}

type ColorKind uint8

const (
	ColorInitial ColorKind = iota
	ColorRGBA
	ColorCurrent
)

type Display uint8

const (
	DisplayInline Display = iota
	DisplayBlock
	DisplayNone
	DisplayFlex
	DisplayListItem
	DisplayTable
	DisplayTableRowGroup
	DisplayTableHeaderGroup
	DisplayTableFooterGroup
	DisplayTableRow
	DisplayTableCell
	DisplayTableCaption
)

type BorderStyle uint8

const (
	BorderNone BorderStyle = iota
	BorderSolid
)

type Border struct {
	Width Length
	Style BorderStyle
	Color Color
}

type Borders struct {
	Top, Right, Bottom, Left Border
}

type FontFamily uint8

const (
	FontSans FontFamily = iota // Inter; sans-serif aliases also select it
	FontMono                   // Fira Code
	FontSerif                  // Noto Serif via the registry's serif role (M99p)
)

type FontWeight uint8

const (
	WeightNormal FontWeight = iota
	WeightBold
)

type FontStyle uint8

const (
	StyleNormal FontStyle = iota
	StyleItalic
)

type TextAlign uint8

const (
	AlignLeft TextAlign = iota
	AlignCenter
	AlignRight
)

type WhiteSpace uint8

const (
	WhiteSpaceNormal WhiteSpace = iota
	WhiteSpacePre
	WhiteSpacePreWrap
)

type FlexDirection uint8

const (
	FlexRow FlexDirection = iota
	FlexColumn
)

type FlexWrap uint8

const (
	FlexNoWrap FlexWrap = iota
	FlexWrapLines
)

type JustifyContent uint8

const (
	JustifyStart JustifyContent = iota
	JustifyEnd
	JustifyCenter
	JustifySpaceBetween
	JustifySpaceAround
	JustifySpaceEvenly
)

type AlignItems uint8

const (
	ItemsStretch AlignItems = iota
	ItemsStart
	ItemsEnd
	ItemsCenter
)

// FlexFactor distinguishes explicit zero from an initial factor.
// Unset resolves to 0 for grow, 1 for shrink; set values are integers 0..16.
type FlexFactor struct {
	Value uint8
	Set   bool
}

// ComputedStyle is one node's resolved cascade, before layout resolves lengths.
// There are no unspecified/inherit flags: Cascade applies inheritance first.
// Initial/auto lengths remain for used-value resolution. Initial font size is 13px;
// initial line height is ceil(size*18/13). Initial min is 0; max is unbounded.
// Initial margins/padding/gaps resolve to 0; dimensions/basis use auto sizing.
// An initial border width is 3px, but a non-solid border has zero used width.
type ComputedStyle struct {
	Display                Display
	Width, Height          Length
	MinWidth, MaxWidth     Length
	MinHeight, MaxHeight   Length
	Margin, Padding        Edges
	Border                 Borders
	FontFamily             FontFamily
	FontSize, LineHeight   Length
	FontWeight             FontWeight
	FontStyle              FontStyle
	Color, BackgroundColor Color
	TextAlign              TextAlign
	WhiteSpace             WhiteSpace
	FlexDirection          FlexDirection
	FlexWrap               FlexWrap
	JustifyContent         JustifyContent
	AlignItems             AlignItems
	FlexGrow, FlexShrink   FlexFactor
	FlexBasis              Length
	RowGap, ColumnGap      Length
}

type DiagnosticKind uint8

const (
	DiagnosticUnsupported DiagnosticKind = iota
	DiagnosticInvalid
	DiagnosticLimit
	DiagnosticResource
)

// Diagnostic locations are 1-based byte positions in the source sheet/HTML.
// Line=Col=0 is reserved for a synthetic UA/runtime diagnostic.
// Text includes the construct and named outcome, never more than 160 bytes.
type Diagnostic struct {
	Kind      DiagnosticKind
	Line, Col uint32
	Text      string
}

// Viewport is the CSS layout size, not a window or scanout rectangle.
type Viewport struct {
	Width, Height int
}

// These are acceptance ceilings, not measured footprints or timings.
const (
	ViewportWidth           = 1280
	ViewportHeight          = 720
	InitialFontSize         = 13
	MaxHTMLBytes            = 1048576
	MaxNodes                = 20000
	MaxDepth                = 256
	MaxStylesheets          = 8
	MaxCSSBytes             = 262144
	MaxCSSRules             = 4096
	MaxSelectorsPerRule     = 16
	MaxSelectorParts        = 16
	MaxDeclarationsPerRule  = 64
	MaxCSSTokenBytes        = 4096
	MaxCSSNesting           = 16
	MaxDiagnostics          = 128
	MaxDiagnosticTextBytes  = 160
	MaxBoxes                = 20000
	MaxPaintItems           = 24000
	MaxReferenceFileBytes   = 16384
	MaxCommittedGoldenBytes = 65536
	MaxImageBytes           = 262144
	MaxImageDimension       = 1024
	MaxImagePixels          = 262144
	MaxDecodedImageBytes    = 1048576
	MaxPageImageBytes       = 2097152
	MaxImages               = 16
	MaxRenderMilliseconds   = 500
	MaxDemandPages          = 3072
	MaxMmapRegions          = 12
)
