/*
	CJPanel - modern UI surfaces for Clipjump (Windows 11 / Fluent look)

	Copyright 2026 Erhan Tuna - part of Clipjump-Ultra (https://github.com/magomic/Clipjump-Ultra)
	Licensed under the Apache License, Version 2.0 (see LICENSE and NOTICE.txt)

	Replaces the BTT tooltips for paste mode, the copy notification and the action mode
	when [Advanced] pasteModeStyle=modern (default).
	  - rounded corners, soft shadow, Segoe UI, accent colour, light/dark theme (follows Windows)
	  - image clips are shown inside the panel (no separate preview window)
	  - never takes focus: WS_EX_NOACTIVATE + click-through, so all hotkeys work as before
	  - persistent layered windows, created at start-up -> no load time when they open

	Surfaces (separate windows, so a copy toast never collides with the paste mode panel):
	  "main"  : paste mode panel, paste mode messages, action mode
	  "toast" : short notifications (copy message)

	Settings ([Advanced] in settings.ini):
	  pasteModeStyle    = modern | classic
	  pasteModeTheme    = auto | light | dark
	  pasteModeHints    = 1 | 0           (key hints in the footer)
	  pasteModeFont     = font for clip contents (default: Segoe UI)
	  pasteModeFontSize = size in px for clip contents (default: 14)

	Public functions:
	  CJPanel_Enabled()
	  CJPanel_Init()
	  CJPanel_ShowClip(info, X, Y)       info: {channel, pos, total, format, pformat, tags, fixed, text, more, image, error,
                                           search: {query, cur, total, placeholder, none, hint}}  (search = Ctrl+F box)
	  CJPanel_ShowMessage(text, X, Y)    first line = title (a TAB splits off a right-aligned part), rest = subtitle
	  CJPanel_ShowToast(text, X, Y)      "Message {Channel}" -> message + channel chip
	  CJPanel_ShowActions(info, X, Y)    info: {title, items: [{key, caption}], footerKey, footer}
	  CJPanel_ShowHold(info, X, Y)       info: {title, channel, text, more, clipImage, items: [{key, caption}]}
	  CJPanel_Follow(surface := "main")  move a visible surface to the mouse again
	  CJPanel_Hide(surface := "")        "" = all surfaces
	  CJPanel_Reset()                    drop all GDI resources (display/power change); re-inits lazily
	All Show* functions return {x, y, w, h} of the panel. X/Y empty = follow the mouse.

	NOTE: AHK variable names are case-insensitive. Never use pairs like y/Y, g/G, w/W in one function.
*/

global CJP	; state object; created in CJPanel_Init() (this file is included after the auto-execute section, so an initializer here would never run)

CJPanel_Enabled(){
	global ini_pasteModeStyle
	return (ini_pasteModeStyle != "classic")
}

CJPanel_Init(){
	global ini_pasteModeFont, ini_pasteModeFontSize
	if (CJP.ready)
		return true
	CJP := {}
	SavedBatchLines := A_BatchLines
	SetBatchLines, -1

	CJP.pToken := Gdip_Startup(1)
	if (!CJP.pToken)
		return false

	scl := CJP.scale := A_ScreenDPI / 96
	CJP.SH := Round(12 * scl)              ; shadow margin around the panel
	CJPanel_LoadSizeSettings()
	CJP.surfaces := {}
	CJPanel_Surface("main")                ; pre-create; "toast" is tiny and created on first use
	CJPanel_Surface("toast")

	; fonts (pixel units, scaled). Static Segoe UI on purpose: GDI+ does not handle the variable
	; "Segoe UI Variable" fonts well (letters end up too close together).
	bodyFont := ini_pasteModeFont != "" ? ini_pasteModeFont : "Segoe UI"
	bodySize := ini_pasteModeFontSize > 0 ? ini_pasteModeFontSize : 14
	CJP.famText := CJPanel_Family(["Segoe UI"])
	CJP.famBold := CJPanel_Family(["Segoe UI Semibold", "Segoe UI"])
	CJP.famBody := CJPanel_Family([bodyFont, "Segoe UI"])
	CJP.fTitle := Gdip_FontCreate(CJP.famBold, 13.5*scl, 0, 2)
	CJP.fBody  := Gdip_FontCreate(CJP.famBody, bodySize*scl, 0, 2)
	CJP.bodyPx := bodySize*scl, CJP.fBodyV := {}   ; bold/italic/underline variants: CJPanel_BodyFont()
	CJP.fList  := Gdip_FontCreate(CJP.famText, 13.5*scl, 0, 2)
	CJP.fMeta  := Gdip_FontCreate(CJP.famText, 12*scl, 0, 2)
	CJP.fChip  := Gdip_FontCreate(CJP.famBold, 11.5*scl, 0, 2)

	; string formats
	CJP.sfLine := Gdip_StringFormatCreate(0x1000)            ; NoWrap: single line
	Gdip_SetStringFormatTrimming(CJP.sfLine, 3)               ; EllipsisCharacter
	CJP.sfRight := Gdip_StringFormatCreate(0x1000)
	Gdip_SetStringFormatAlign(CJP.sfRight, 2)                 ; far
	CJP.sfCenter := Gdip_StringFormatCreate(0x1000)
	Gdip_SetStringFormatAlign(CJP.sfCenter, 1)                ; centre
	CJP.sfWrap := Gdip_StringFormatCreate(0x2000)            ; LineLimit: only whole lines
	Gdip_SetStringFormatTrimming(CJP.sfWrap, 3)
	Gdip_SetStringFormatTabStops(CJP.sfWrap, [32*scl])
	; typographic format (no padding) for the syntax highlighter: pieces are measured and placed
	; one after another, so widths must add up exactly. Cloned: the generic object must not be changed.
	DllCall("gdiplus\GdipCloneStringFormat", "UPtr", Gdip_StringFormatGetGeneric(1), "UPtr*", sfTypo)
	CJP.sfTypo := sfTypo
	Gdip_SetStringFormatFlags(CJP.sfTypo, 0x4 | 0x800 | 0x1000 | 0x4000)  ; NoFitBlackBox|MeasureTrailingSpaces|NoWrap|NoClip

	CJP.G := CJP.surfaces.main.G          ; graphics used for measuring
	CJP.imgCache := {}, CJP.imgOrder := []
	CJP.themeKey := ""
	CJP.ready := true
	SetBatchLines, %SavedBatchLines%
	return true
}

; one layered window + DIB + graphics per surface
CJPanel_Surface(name){
	if (srf := CJP.surfaces[name])
		return srf
	srf := {name: name}
	if (name = "main")   ; big enough for the largest panel: max (action mode / configured) width x primary screen height
		srf.cw := Ceil((Max(CJPanel_Const("maxWideCW"), CJP.maxCW) + 2*CJPanel_Const("pad")) * CJP.scale) + 2*CJP.SH
		, srf.ch := A_ScreenHeight + 2*CJP.SH
	else
		srf.cw := Ceil(560 * CJP.scale) + 2*CJP.SH, srf.ch := Ceil(240 * CJP.scale) + 2*CJP.SH   ; room for a few subtitle lines
	gname := "CJPanel_" name
	; E0x80000 = WS_EX_LAYERED, 0x08000000 = WS_EX_NOACTIVATE, 0x20 = WS_EX_TRANSPARENT (click-through)
	Gui, %gname%: New, +E0x80000 +E0x08000020 -Caption +ToolWindow +AlwaysOnTop -DPIScale +HwndhSrf
	Gui, %gname%: Show, NA Hide, Clipjump_Panel_%name%
	srf.gui := gname, srf.hwnd := hSrf, srf.visible := 0
	srf.hbm := CreateDIBSection(srf.cw, srf.ch)
	srf.hdc := CreateCompatibleDC()
	srf.obm := SelectObject(srf.hdc, srf.hbm)
	srf.G := Gdip_GraphicsFromHDC(srf.hdc)
	Gdip_SetSmoothingMode(srf.G, 4)
	Gdip_SetPixelOffsetMode(srf.G, 2)
	Gdip_SetInterpolationMode(srf.G, 7)
	Gdip_SetCompositingQuality(srf.G, 2)
	CJP.surfaces[name] := srf
	return srf
}

CJPanel_Reset(){
	if (!CJP.ready)
		return
	for k, v in CJP.imgCache
		Gdip_DisposeImage(v.bmp)
	if (CJP.frame)
		Gdip_DisposeImage(CJP.frame)
	for k, f in ["fTitle", "fBody", "fList", "fMeta", "fChip"]
		Gdip_DeleteFont(CJP[f])
	for k, f in CJP.fBodyV
		Gdip_DeleteFont(f)
	CJP.fBodyV := {}
	for k, f in ["sfLine", "sfRight", "sfCenter", "sfWrap", "sfTypo"]
		Gdip_DeleteStringFormat(CJP[f])
	for k, f in ["famText", "famBold", "famBody"]
		Gdip_DeleteFontFamily(CJP[f])
	for name, srf in CJP.surfaces {
		Gdip_DeleteGraphics(srf.G)
		SelectObject(srf.hdc, srf.obm)
		DeleteObject(srf.hbm)
		DeleteDC(srf.hdc)
		gname := srf.gui
		Gui, %gname%: Destroy
	}
	Gdip_Shutdown(CJP.pToken)
	CJP := {}
}

CJPanel_Hide(surface := ""){
	if (!CJP.ready)
		return
	for name, srf in CJP.surfaces
		if ((surface = "" || surface = name) && srf.visible) {
			gname := srf.gui
			Gui, %gname%: Hide
			srf.visible := 0
		}
}

CJPanel_ShowClip(info, X:="", Y:=""){
	return CJPanel_Render("clip", info, X, Y)
}

CJPanel_ShowMessage(text, X:="", Y:=""){
	return CJPanel_Render("msg", {text: text}, X, Y)
}

; icon: "check" (done), "busy" (three dots, e.g. "Processing..."), "warn", "info" or "pause".
; text: first line = title, further lines = subtitle, "{Channel}" at the end = chip.
; While the toast is visible it keeps its position, so "Processing..." -> "Transferred..." is one window.
CJPanel_ShowToast(text, X:="", Y:="", icon:="check"){
	return CJPanel_Render("toast", {text: text, icon: icon}, X, Y)
}

CJPanel_ShowActions(info, X:="", Y:=""){
	return CJPanel_Render("actions", info, X, Y)
}

; info: {title, channel, text, more, clipImage, items: [{key, caption}]}
; clipImage = 1: the preview is the image on the clipboard (used when there is no text)
CJPanel_ShowHold(info, X:="", Y:=""){
	if !CJPanel_Init()
		return {}
	if (info.clipImage) {
		bmp := Gdip_CreateBitmapFromClipboard()
		info.bitmap := (bmp > 0) ? bmp : ""
	}
	token := CJP.pToken
	ret := CJPanel_Render("hold", info, X, Y)
	if (info.bitmap && CJP.pToken = token)   ; a GDI+ restart (see CJPanel_Render) already freed it
		Gdip_DisposeImage(info.bitmap)
	return ret
}

; moves a visible surface to the mouse again (same placement rules as when it was shown)
CJPanel_Follow(surface := "main"){
	if (!CJP.ready)
		return
	srf := CJP.surfaces[surface]
	if (!srf.visible || !IsObject(a := srf.anchor))
		return
	pos := CJPanel_Position("", "", a.w, a.h)
	if (pos.x = a.x && pos.y = a.y)
		return
	; SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE: the layered bitmap stays as it is
	DllCall("SetWindowPos", "ptr", srf.hwnd, "ptr", 0, "int", pos.x - CJP.SH, "int", pos.y - CJP.SH, "int", 0, "int", 0, "uint", 0x0001 | 0x0004 | 0x0010)
	a.x := pos.x, a.y := pos.y
}

;------------------------------------------------------------------------------------------------

CJPanel_Const(name){
	static c := {pad: 14, padV: 12, radius: 8, minCW: 300, maxCW: 480, maxWideCW: 640, msgMinCW: 200
		, maxTextLines: 12, maxImgH: 280, chipH: 20, chipPad: 8, gap: 8}
	return c[name]
}

CJPanel_Family(names){
	for k, n in names
		if (f := Gdip_FontFamilyCreate(n))
			return f
	return 0
}

CJPanel_Render(kind, info, X, Y){
	if !CJPanel_Init()
		return {}
	ret := CJPanel_Draw(kind, info, X, Y, ok)
	if (!ok) {
		; layered window lost its GDI state (display power-cycle, driver reset, ...): rebuild once
		CJPanel_Reset()
		info.bitmap := ""    ; a GDI+ bitmap of the caller died with the reset
		if !CJPanel_Init()
			return {}
		ret := CJPanel_Draw(kind, info, X, Y, ok)
	}
	return ret
}

CJPanel_Draw(kind, info, X, Y, ByRef ok){
	SavedBatchLines := A_BatchLines
	SetBatchLines, -1
	ok := 1
	srf := CJPanel_Surface(kind = "toast" ? "toast" : "main")
	scl := CJP.scale, G := srf.G, SH := CJP.SH
	CJP.G := G
	T := CJPanel_Theme()
	pad := Round(CJPanel_Const("pad")*scl), padV := Round(CJPanel_Const("padV")*scl), gap := Round(CJPanel_Const("gap")*scl)
	chipPad := Round(CJPanel_Const("chipPad")*scl), chipH := Round(CJPanel_Const("chipH")*scl)
	maxCW := Round(CJP.maxCW*scl)

	; ================= measure =================
	if (kind = "msg")
	{
		lines := StrSplit(RTrim(info.text, "`r`n"), "`n", "`r")
		title := lines.RemoveAt(1)
		titleRight := ""
		if (p := InStr(title, "`t"))
			titleRight := Trim(SubStr(title, p), " `t"), title := RTrim(SubStr(title, 1, p-1))
		sub := ""
		for k, v in lines
			sub .= (k>1 ? "`n" : "") Trim(v, " `t")

		tw := CJPanel_TextW(title, CJP.fTitle) + (titleRight!="" ? gap*2 + CJPanel_TextW(titleRight, CJP.fMeta) : 0)
		subSize := sub!="" ? CJPanel_Measure(sub, CJP.fMeta, maxCW, 0) : {w:0, h:0}
		CW := Min(maxCW, Max(Round(CJPanel_Const("msgMinCW")*scl), tw, subSize.w))
		titleH := Round(20*scl)
		H := padV + titleH + (sub!="" ? Round(4*scl) + subSize.h : 0) + padV
	}
	else if (kind = "toast")
	{
		; "Title`nmore lines {Channel}": first line = title, further lines = subtitle, {..} at the end = chip
		title := RTrim(info.text, " `t`r`n"), chipTxt := ""
		if RegExMatch(title, "s)^(.*?)\s*\{([^{}]*)\}\s*$", mt)
			title := mt1, chipTxt := mt2
		sub := ""
		if (p := InStr(title, "`n")) {
			lines := StrSplit(SubStr(title, p+1), "`n", "`r")
			title := RTrim(SubStr(title, 1, p-1), " `t`r")
			for k, v in lines
				if ((v := Trim(v, " `t")) != "")
					sub .= (sub != "" ? "`n" : "") v
		}
		iconD := Round(20*scl), titleH := Round(20*scl), iconGap := Round(10*scl)
		titleW := CJPanel_TextW(title, CJP.fTitle)
		chipW := chipTxt != "" ? CJPanel_TextW(chipTxt, CJP.fChip) + 2*chipPad : 0
		maxToastCW := srf.cw - 2*SH - 2*pad
		subSize := sub != "" ? CJPanel_Measure(sub, CJP.fMeta, maxToastCW - iconD - iconGap, Round(160*scl)) : {w: 0, h: 0}
		CW := iconD + iconGap + Max(titleW + (chipW ? iconGap + chipW : 0), subSize.w)
		CW := Min(CW, maxToastCW)
		padV := Round(10*scl)
		H := padV + Max(iconD, titleH) + (sub != "" ? Round(2*scl) + subSize.h : 0) + padV
	}
	else if (kind = "actions")
	{
		items := info.items, cols := (info.columns = 1) ? 1 : 2   ; columns = 1: one list (long captions)
		rowH := Round((cols = 1 ? 26 : 28)*scl), colGap := Round(24*scl), titleH := Round(22*scl)
		keyW := Round(30*scl)
		for k, it in items
			keyW := Max(keyW, CJPanel_TextW(it.key, CJP.fChip) + 2*chipPad)
		capW := 0
		for k, it in items
			capW := Max(capW, CJPanel_TextW(it.caption, CJP.fList))
		capW := Min(capW, (Round(CJPanel_Const("maxWideCW")*scl) - (cols-1)*colGap)//cols - keyW - gap)
		colW := keyW + gap + capW
		rows := Ceil(items.Length() / cols)
		CW := Max(cols*colW + (cols-1)*colGap, CJPanel_TextW(info.title, CJP.fTitle))
		footer := info.footer != "" ? 1 : 0
		H := padV + titleH + gap + 1 + gap + rows*rowH + (footer ? gap + 1 + gap + rowH : 0) + padV - Round(4*scl)
	}
	else if (kind = "hold")
	{
		; header (accent dot, title, channel chip) | clip preview | key rows in two columns
		headerH := Round(20*scl), rowH := Round(28*scl), colGap := Round(24*scl)
		title := info.title, chipTxt := info.channel
		chipW := chipTxt != "" ? CJPanel_TextW(chipTxt, CJP.fChip) + 2*chipPad : 0
		items := info.items
		keyW := Round(30*scl), capW := 0
		for k, it in items
			keyW := Max(keyW, CJPanel_TextW(it.key, CJP.fChip) + 2*chipPad)
			, capW := Max(capW, CJPanel_TextW(it.caption, CJP.fList))
		capW := Min(capW, (Round(CJPanel_Const("maxWideCW")*scl) - colGap)//2 - keyW - gap)   ; as wide as the action mode
		colW := keyW + gap + capW
		rows := Ceil(items.Length() / 2)
		holdMaxCW := Max(maxCW, 2*colW + colGap)
		CW := Max(Round(CJPanel_Const("minCW")*scl), 2*colW + colGap
			, Round(16*scl) + CJPanel_TextW(title, CJP.fTitle) + (chipW ? gap*2 + chipW : 0))
		CW := Min(CW, holdMaxCW)
		bd := CJPanel_BodyMeasure(info, T, CW, holdMaxCW)   ; may widen CW for the preview
		H := padV + headerH + gap + 1 + gap + bd.h + gap + 1 + gap + rows*rowH + padV - Round(4*scl)
	}
	else ; clip
	{
		header := info.channel
		counter := info.pos " / " info.total
		chips := []
		if (info.format != "")
			chips.Push({t: info.format})
		if (info.rich != "")      ; HTML / Link / RTF stored with the clip
			chips.Push({t: info.rich})
		if (info.pformat != "")
			chips.Push({t: info.pformat})
		for k, tag in StrSplit(info.tags, ",")
			if ((tag := Trim(tag)) != "")
				chips.Push({t: "# " tag})
		if (info.fixed != "")
			chips.Push({t: info.fixed, accent: 1})
		chipsW := 0
		for k, chp in chips
			chp.w := CJPanel_TextW(chp.t, CJP.fChip) + 2*chipPad
			, chipsW += chp.w + (k>1 ? Round(6*scl) : 0)

		headerW := Round(16*scl) + CJPanel_TextW(header, CJP.fTitle) + gap*2 + CJPanel_TextW(counter, CJP.fMeta)
		CW := Max(Round(CJPanel_Const("minCW")*scl), headerW, Min(chipsW, maxCW))
		srch := IsObject(info.search) ? info.search : ""   ; search in paste mode (Ctrl+F): search box below the header
		sbH := srch ? Round(32*scl) : 0
		if (srch)
			CW := Max(CW, Min(maxCW, Round(360*scl)))

		bd := CJPanel_BodyMeasure(info, T, CW, maxCW)
		bmp := bd.bmp, contentH := bd.h
		hint := ""
		if (srch && srch.hint != "")
			hint := srch.hint, CW := Max(CW, CJPanel_TextW(hint, CJP.fMeta))
		else if (CJPanel_Hints())
			hint := CJPanel_HintText(), CW := Max(CW, CJPanel_TextW(hint, CJP.fMeta))
		CW := Min(CW, maxCW)
		headerH := Round(20*scl)
		urlH := (info.url != "" && !bmp) ? Round(18*scl) : 0   ; link target below the preview
		H := padV + headerH
			+ (sbH ? Round(10*scl) + sbH : 0)
			+ (chips.Length() ? Round(6*scl) + chipH : 0)
			+ gap + 1 + gap + contentH
			+ (urlH ? Round(6*scl) + urlH : 0)
			+ (hint != "" ? gap + 1 + Round(7*scl) + Round(16*scl) : 0)
			+ padV
	}
	W := CW + 2*pad
	W := Min(W, srf.cw - 2*SH), H := Min(H, srf.ch - 2*SH)

	; ================= paint =================
	Gdip_GraphicsClear(G)
	Gdip_SetTextRenderingHint(G, 5)     ; ClearType on the opaque panel
	CJPanel_PaintFrame(G, T, W + 2*SH, H + 2*SH)   ; shadow + border + background (9-slice)

	; the drawing cursor is "cy" - never "y" (case-insensitive: it would overwrite the Y parameter)
	x0 := SH + pad, cy := SH + padV
	if (kind = "msg")
	{
		CJPanel_Text(title, CJP.fTitle, T.text, x0, cy, CW, titleH, CJP.sfLine)
		if (titleRight != "")
			CJPanel_Text(titleRight, CJP.fMeta, T.text2, x0, cy + Round(1*scl), CW, titleH, CJP.sfRight)
		cy += titleH
		if (sub != "")
			CJPanel_Text(sub, CJP.fMeta, T.text2, x0, cy + Round(4*scl), CW, subSize.h, CJP.sfWrap)
	}
	else if (kind = "toast")
	{
		rowH := Max(iconD, titleH)   ; icon, title and chip share the first row; the subtitle goes below
		ic := cy + (rowH - iconD)//2
		CJPanel_ToastIcon(G, T, info.icon, x0, ic, iconD)
		tx := x0 + iconD + iconGap
		tMax := CW - (tx - x0) - (chipW ? iconGap + chipW : 0)
		CJPanel_Text(title, CJP.fTitle, T.text, tx, cy + (rowH - titleH)//2, tMax + 2, titleH, CJP.sfLine)
		if (sub != "")
			CJPanel_Text(sub, CJP.fMeta, T.text2, tx, cy + rowH + Round(2*scl), CW - (tx - x0) + 2, subSize.h + 2, CJP.sfWrap)
		if (chipW) {
			cx := x0 + CW - chipW, ccy := cy + (rowH - chipH)//2
			pB := Gdip_BrushCreateSolid(T.accentSoft)
			Gdip_FillRoundedRectanglePath(G, pB, cx, ccy, chipW, chipH, chipH//2)
			Gdip_DeleteBrush(pB)
			CJPanel_Text(chipTxt, CJP.fChip, T.accentText, cx, ccy + Round(2*scl), chipW, chipH, CJP.sfCenter)
		}
	}
	else if (kind = "actions")
	{
		pB := Gdip_BrushCreateSolid(T.accent)
		d := Round(8*scl)
		Gdip_FillEllipse(G, pB, x0, cy + (titleH-d)//2, d, d)
		Gdip_DeleteBrush(pB)
		CJPanel_Text(info.title, CJP.fTitle, T.text, x0 + Round(16*scl), cy + Round(1*scl), CW - Round(16*scl), titleH, CJP.sfLine)
		cy += titleH + gap
		CJPanel_Sep(G, T, SH + 1, cy, W - 2)
		cy += 1 + gap
		for k, it in items {
			col := (k > rows), row := col ? k - rows - 1 : k - 1
			CJPanel_KeyRow(G, T, it.key, it.caption, x0 + col*(colW + colGap), cy + row*rowH, keyW, capW, rowH, chipH)
		}
		cy += rows*rowH
		if (footer) {
			cy += gap
			CJPanel_Sep(G, T, SH + 1, cy, W - 2)
			cy += 1 + gap
			CJPanel_KeyRow(G, T, info.footerKey, info.footer, x0, cy, keyW, CW - keyW - gap, rowH, chipH, 1)
		}
	}
	else if (kind = "hold")
	{
		d := Round(8*scl)
		pB := Gdip_BrushCreateSolid(T.accent)
		Gdip_FillEllipse(G, pB, x0, cy + (headerH-d)//2, d, d)
		Gdip_DeleteBrush(pB)
		if (chipW) {
			cx := x0 + CW - chipW, ccy := cy + (headerH - chipH)//2
			pB := Gdip_BrushCreateSolid(T.accentSoft)
			Gdip_FillRoundedRectanglePath(G, pB, cx, ccy, chipW, chipH, chipH//2)
			Gdip_DeleteBrush(pB)
			CJPanel_Text(chipTxt, CJP.fChip, T.accentText, cx, ccy + Round(2*scl), chipW, chipH, CJP.sfCenter)
		}
		CJPanel_Text(title, CJP.fTitle, T.text, x0 + Round(16*scl), cy
			, CW - Round(16*scl) - (chipW ? chipW + gap : 0), headerH, CJP.sfLine)
		cy += headerH + gap
		CJPanel_Sep(G, T, SH + 1, cy, W - 2)
		cy += 1 + gap
		CJPanel_BodyDraw(G, T, bd, x0, cy, CW)
		cy += bd.h + gap
		CJPanel_Sep(G, T, SH + 1, cy, W - 2)
		cy += 1 + gap
		for k, it in items {
			col := (k > rows), row := col ? k - rows - 1 : k - 1
			CJPanel_KeyRow(G, T, it.key, it.caption, x0 + col*(colW + colGap), cy + row*rowH, keyW, capW, rowH, chipH)
		}
	}
	else ; clip
	{
		; header: accent dot, channel, counter
		d := Round(8*scl)
		pB := Gdip_BrushCreateSolid(T.accent)
		Gdip_FillEllipse(G, pB, x0, cy + (headerH-d)//2, d, d)
		Gdip_DeleteBrush(pB)
		CJPanel_Text(counter, CJP.fMeta, T.text2, x0, cy + Round(1*scl), CW, headerH, CJP.sfRight)
		cntW := CJPanel_TextW(counter, CJP.fMeta)
		CJPanel_Text(header, CJP.fTitle, T.text, x0 + Round(16*scl), cy, CW - Round(16*scl) - cntW - gap, headerH, CJP.sfLine)
		cy += headerH

		; search box (Ctrl+F)
		if (sbH) {
			cy += Round(10*scl)
			CJPanel_SearchBox(G, T, srch, x0, cy, CW, sbH)
			cy += sbH
		}

		; chips
		if (chips.Length()) {
			cy += Round(6*scl), cx := x0
			for k, chp in chips {
				if (cx + chp.w > x0 + CW)
					break
				pB := Gdip_BrushCreateSolid(chp.accent ? T.accentSoft : T.chip)
				Gdip_FillRoundedRectanglePath(G, pB, cx, cy, chp.w, chipH, chipH//2)
				Gdip_DeleteBrush(pB)
				CJPanel_Text(chp.t, CJP.fChip, chp.accent ? T.accentText : T.text2
					, cx, cy + Round(2*scl), chp.w, chipH, CJP.sfCenter)
				cx += chp.w + Round(6*scl)
			}
			cy += chipH
		}

		cy += gap
		CJPanel_Sep(G, T, SH + 1, cy, W - 2)
		cy += 1 + gap

		; content
		CJPanel_BodyDraw(G, T, bd, x0, cy, CW)
		cy += contentH
		if (urlH) {
			cy += Round(6*scl)
			CJPanel_Text(Chr(0x2197) "  " info.url, CJP.fMeta, T.accentText = 0xFFFFFFFF ? T.accent : T.accentText
				, x0, cy, CW, urlH, CJP.sfLine)
			cy += urlH
		}

		; footer hints
		if (hint != "") {
			cy += gap
			CJPanel_Sep(G, T, SH + 1, cy, W - 2)
			cy += 1 + Round(7*scl)
			CJPanel_Text(hint, CJP.fMeta, T.text3, x0, cy, CW, Round(16*scl), CJP.sfLine)
		}
	}

	; ================= position + show =================
	if (kind = "toast" && X = "" && Y = "" && srf.visible && IsObject(srf.anchor))
		pos := CJPanel_Position(srf.anchor.x, srf.anchor.y, W, H)   ; visible toast: stay where it is
	else
		pos := CJPanel_Position(X, Y, W, H)
	pos.w := W, pos.h := H
	srf.anchor := pos
	ok := UpdateLayeredWindow(srf.hwnd, srf.hdc, pos.x - SH, pos.y - SH, W + 2*SH, H + 2*SH)
	if (ok) {
		; same z-order/visibility nudges as BTT (see comments there)
		DllCall("SetWindowPos", "ptr", srf.hwnd, "ptr", -1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x0013 | 0x0200 | 0x0400)
		gname := srf.gui
		Gui, %gname%: Show, NA
		srf.visible := 1
	}
	SetBatchLines, %SavedBatchLines%
	return {x: pos.x, y: pos.y, w: W, h: H}
}

; clip preview (image or text) of the "clip" and "hold" panels: measures it and widens CW
; (up to maxCW) when the content needs it. Returns {bmp, imgW, imgH | body, lay, err; h}
CJPanel_BodyMeasure(info, T, ByRef CW, maxCW){
	scl := CJP.scale, bd := {}
	bmp := info.bitmap ? info.bitmap : (info.image != "" ? CJPanel_GetImage(info.image) : "")
	if (bmp) {
		Gdip_GetImageDimensions(bmp, iw, ih)
		fct := Min(1, maxCW/iw, (CJPanel_Const("maxImgH")*scl)/ih)
		bd.bmp := bmp, bd.imgW := Round(iw*fct), bd.imgH := Round(ih*fct)
		CW := Max(CW, bd.imgW), bd.h := bd.imgH
		return bd
	}
	bd.err := (info.error != "")
	body := bd.err ? info.error : info.text
	body := RegExReplace(body, "[\r\n]+$")
	if (info.more)
		body .= " " Chr(0x2026)     ; ellipsis (kept ASCII-only: this file has no BOM)
	bd.body := body
	lineH := Gdip_GetFontHeight(CJP.fBody, CJP.G)
	lay := ""
	if (!bd.err && info.html != "")     ; formatted text (HTML of the clip; only without a paste format)
		lay := CJPanel_HtmlRuns(info.html, T)
	if (!lay && !bd.err && CJPanel_HighlightOn())
		lay := CJPanel_Highlight(body, T)
	if (!bd.err && IsObject(info.search) && Trim(info.search.query) != "")   ; search: mark the matches
		lay := CJPanel_MarkRuns(lay ? lay : [{t: body, c: T.text}], info.search.query, T)
	if (lay) {   ; syntax highlighted / search matches: own layout of coloured pieces
		bd.lay := CJPanel_Layout(lay, maxCW, CJP.maxLines, lineH)
		CW := Min(maxCW, Max(CW, bd.lay.w))
		bd.h := Max(bd.lay.h, Ceil(lineH))
	} else {
		maxTextH := Ceil(lineH * CJP.maxLines)
		bs := CJPanel_Measure(body, CJP.fBody, maxCW, maxTextH)
		CW := Min(maxCW, Max(CW, bs.w))
		bs := CJPanel_Measure(body, CJP.fBody, CW, maxTextH)
		bd.h := Max(bs.h, Ceil(lineH))
	}
	return bd
}

CJPanel_BodyDraw(G, T, bd, px, py, CW){
	if (bd.bmp) {
		ix := px + (CW - bd.imgW)//2
		pPath := Gdip_CreatePath()
		Gdip_AddPathRoundedRectangle(pPath, ix, py, bd.imgW, bd.imgH, Round(4*CJP.scale))
		Gdip_SetClipPath(G, pPath)
		Gdip_DrawImage(G, bd.bmp, ix, py, bd.imgW, bd.imgH)
		Gdip_ResetClip(G)
		Gdip_DeletePath(pPath)
	} else if (bd.lay)
		CJPanel_DrawLayout(G, bd.lay, px, py)
	else
		CJPanel_Text(bd.body, CJP.fBody, bd.err ? T.text2 : T.text, px, py, CW, bd.h + 2, CJP.sfWrap)
}

; round toast icon: "check" (done), "busy" (three dots), "warn" (!), "info" (i), "pause" (two bars)
CJPanel_ToastIcon(G, T, icon, px, py, d){
	scl := CJP.scale
	pB := Gdip_BrushCreateSolid(icon = "warn" ? T.warn : T.accent)
	Gdip_FillEllipse(G, pB, px, py, d, d)
	Gdip_DeleteBrush(pB)
	fg := icon = "warn" ? T.onWarn : T.onAccent
	if (icon = "busy") {
		pB := Gdip_BrushCreateSolid(fg), dd := d*0.16
		loop 3
			Gdip_FillEllipse(G, pB, px + d*(0.14 + 0.27*A_Index) - dd, py + d/2 - dd/2, dd, dd)
		Gdip_DeleteBrush(pB)
	} else if (icon = "warn" || icon = "info") {   ; "!" = bar above dot, "i" = dot above bar
		pB := Gdip_BrushCreateSolid(fg), bw := Max(2, d*0.12), dd := d*0.15
		barY := icon = "warn" ? py + d*0.22 : py + d*0.43, dotY := icon = "warn" ? py + d*0.66 : py + d*0.2
		Gdip_FillRoundedRectanglePath(G, pB, px + (d - bw)/2, barY, bw, d*0.36, bw/2)
		Gdip_FillEllipse(G, pB, px + (d - dd)/2, dotY, dd, dd)
		Gdip_DeleteBrush(pB)
	} else if (icon = "pause") {
		pB := Gdip_BrushCreateSolid(fg), bw := Max(2, d*0.12)
		Gdip_FillRoundedRectanglePath(G, pB, px + d*0.36 - bw/2, py + d*0.3, bw, d*0.4, bw/2)
		Gdip_FillRoundedRectanglePath(G, pB, px + d*0.64 - bw/2, py + d*0.3, bw, d*0.4, bw/2)
		Gdip_DeleteBrush(pB)
	} else {                    ; check mark
		pP := Gdip_CreatePen(fg, 1.8*scl)
		Gdip_DrawLine(G, pP, px + d*0.29, py + d*0.52, px + d*0.44, py + d*0.67)
		Gdip_DrawLine(G, pP, px + d*0.44, py + d*0.67, px + d*0.72, py + d*0.37)
		Gdip_DeletePen(pP)
	}
}

CJPanel_Sep(G, T, px, py, pw){
	pB := Gdip_BrushCreateSolid(T.sep)
	Gdip_FillRectangle(G, pB, px, py, pw, 1)
	Gdip_DeleteBrush(pB)
}

; key badge + caption, vertically centred in a row
CJPanel_KeyRow(G, T, key, caption, px, py, keyW, capW, rowH, chipH, muted:=0){
	by := py + (rowH - chipH)//2 - Round(2*CJP.scale)
	pB := Gdip_BrushCreateSolid(T.chip)
	Gdip_FillRoundedRectanglePath(G, pB, px, by, keyW, chipH, Round(4*CJP.scale))
	Gdip_DeleteBrush(pB)
	CJPanel_Text(key, CJP.fChip, T.text, px, by + Round(2*CJP.scale), keyW, chipH, CJP.sfCenter)
	lh := Round(20*CJP.scale)
	CJPanel_Text(caption, CJP.fList, muted ? T.text2 : T.text, px + keyW + Round(8*CJP.scale)
		, by + (chipH - lh)//2, capW + 2, lh, CJP.sfLine)
}

; Shadow + border + background. Painting the soft shadow directly costs ~30 ms per draw, so a
; small template (corners + a uniform middle strip) is rendered once per theme and stretched
; to the window size with 9 DrawImage calls (~0.3 ms).
CJPanel_PaintFrame(G, T, winW, winH){
	scl := CJP.scale, SH := CJP.SH, R := Round(CJPanel_Const("radius")*scl)
	cs := SH + R + Round(3*scl)  ; corner slice size (covers shadow + rounded corner + offset)
	M := 8                       ; uniform middle strip, sampled from its centre
	if (CJP.frameKey != CJP.themeKey || !CJP.frame) {
		if (CJP.frame)
			Gdip_DisposeImage(CJP.frame)
		tw := 2*cs + M
		bmp := Gdip_CreateBitmap(tw, tw)
		gT := Gdip_GraphicsFromImage(bmp)
		Gdip_SetSmoothingMode(gT, 4), Gdip_SetPixelOffsetMode(gT, 2)
		pw := tw - 2*SH          ; template panel size
		sumSq := SH*(SH+1)*(2*SH+1)/6     ; rings stack up -> spread total alpha T.shadowA over all rings
		loop, % SH
		{
			i := SH - A_Index + 1
			a := Round(T.shadowA * A_Index**2 / sumSq)
			if (a < 1)
				continue
			pB := Gdip_BrushCreateSolid(a << 24)
			Gdip_FillRoundedRectanglePath(gT, pB, SH-i, SH-i + Round(2*scl), pw + 2*i, pw + 2*i, R + i)
			Gdip_DeleteBrush(pB)
		}
		pB := Gdip_BrushCreateSolid(T.border)
		Gdip_FillRoundedRectanglePath(gT, pB, SH, SH, pw, pw, R)
		Gdip_DeleteBrush(pB)
		pB := Gdip_BrushCreateSolid(T.bg)
		Gdip_FillRoundedRectanglePath(gT, pB, SH+1, SH+1, pw-2, pw-2, R-1)
		Gdip_DeleteBrush(pB)
		Gdip_DeleteGraphics(gT)
		CJP.frame := bmp, CJP.frameKey := CJP.themeKey
	}
	fr := CJP.frame, m0 := cs + M//2 - 1, ms := 2   ; source sample of the uniform strip
	iw := winW - 2*cs, ih := winH - 2*cs
	Gdip_SetCompositingMode(G, 1)     ; SourceCopy: first layer on a cleared canvas, fastest
	Gdip_SetInterpolationMode(G, 5)   ; nearest neighbour: no bleeding when stretching
	; corners
	Gdip_DrawImage(G, fr, 0, 0, cs, cs, 0, 0, cs, cs)
	Gdip_DrawImage(G, fr, winW-cs, 0, cs, cs, cs+M, 0, cs, cs)
	Gdip_DrawImage(G, fr, 0, winH-cs, cs, cs, 0, cs+M, cs, cs)
	Gdip_DrawImage(G, fr, winW-cs, winH-cs, cs, cs, cs+M, cs+M, cs, cs)
	; edges
	Gdip_DrawImage(G, fr, cs, 0, iw, cs, m0, 0, ms, cs)
	Gdip_DrawImage(G, fr, cs, winH-cs, iw, cs, m0, cs+M, ms, cs)
	Gdip_DrawImage(G, fr, 0, cs, cs, ih, 0, m0, cs, ms)
	Gdip_DrawImage(G, fr, winW-cs, cs, cs, ih, cs+M, m0, cs, ms)
	; centre is plain background
	pB := Gdip_BrushCreateSolid(T.bg)
	Gdip_FillRectangle(G, pB, cs, cs, iw, ih)
	Gdip_DeleteBrush(pB)
	Gdip_SetCompositingMode(G, 0)
	Gdip_SetInterpolationMode(G, 7)
}

; follows the mouse when X/Y are empty, stays inside the work area of the monitor, never under the cursor
CJPanel_Position(X, Y, W, H){
	VarSetCapacity(pt, 8, 0)
	DllCall("GetCursorPos", "Ptr", &pt)
	mx := NumGet(pt, 0, "Int"), my := NumGet(pt, 4, "Int")
	off := Round(16*CJP.scale)
	px := (X = "") ? mx + off : X
	py := (Y = "") ? my + off : Y
	ax := (X = "") ? mx : X, ay := (Y = "") ? my : Y
	m := MDMF_GetInfo(MDMF_FromPoint(ax, ay, 2))
	if !IsObject(m)
		m := {WALeft: 0, WATop: 0, WARight: A_ScreenWidth, WABottom: A_ScreenHeight}
	if (px + W > m.WARight)
		px := m.WARight - W
	if (py + H > m.WABottom)
		py := m.WABottom - H
	px := Max(px, m.WALeft), py := Max(py, m.WATop)
	if ((X = "" or Y = "") && mx >= px && mx <= px + W && my >= py && my <= py + H)
		py := (my - H - off >= m.WATop) ? my - H - off : (my + off + H <= m.WABottom ? my + off : py)
	return {x: Round(px), y: Round(py)}
}

CJPanel_Theme(){
	global ini_pasteModeTheme
	if (ini_pasteModeTheme = "dark" || ini_pasteModeTheme = "light")
		dark := (ini_pasteModeTheme = "dark")
	else {
		RegRead, light, HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize, AppsUseLightTheme
		dark := (light = 0)
	}
	RegRead, ac, HKCU\Software\Microsoft\Windows\DWM, AccentColor     ; 0xAABBGGRR
	key := dark "|" ac
	if (key == CJP.themeKey)
		return CJP.T
	if (ac = "")
		r := 0x00, g := 0x67, b := 0xC0
	else
		r := ac & 0xFF, g := (ac >> 8) & 0xFF, b := (ac >> 16) & 0xFF
	if (dark) ; lighter accent tint reads better on dark backgrounds
		r := r + (255-r)*0.35, g := g + (255-g)*0.35, b := b + (255-b)*0.35
	accentRGB := (Round(r) << 16) | (Round(g) << 8) | Round(b)
	if (dark)
		T := {bg: 0xFF2B2B2B, border: 0xFF3D3D3D, text: 0xFFFFFFFF, text2: 0xFFC8C8C8, text3: 0xFF9A9A9A
			, sep: 0xFF3A3A3A, chip: 0xFF3A3A3A, shadowA: 0x90, onAccent: 0xFF1B1B1B}
	else
		T := {bg: 0xFFF9F9F9, border: 0xFFDCDCDC, text: 0xFF1B1B1B, text2: 0xFF5C5C5C, text3: 0xFF8A8A8A
			, sep: 0xFFE6E6E6, chip: 0xFFEBEBEB, shadowA: 0x60, onAccent: 0xFFFFFFFF}
	; syntax highlighter colours (close to VS Code "Dark+" / "Light+")
	if (dark)
		T.hl := {tag: 0xFF569CD6, attr: 0xFF9CDCFE, value: 0xFFCE9178, punct: 0xFF808080, comment: 0xFF6A9955
			, entity: 0xFFD7BA7D, key: 0xFF9CDCFE, string: 0xFFCE9178, number: 0xFFB5CEA8, keyword: 0xFF569CD6, text: T.text
			, variable: 0xFF9CDCFE, cmdlet: 0xFFDCDCAA, param: 0xFFA9A9A9, type: 0xFF4EC9B0, control: 0xFFC586C0}
	else
		T.hl := {tag: 0xFF800000, attr: 0xFFE50000, value: 0xFF0000FF, punct: 0xFF800000, comment: 0xFF008000
			, entity: 0xFFEE0000, key: 0xFF0451A5, string: 0xFFA31515, number: 0xFF098658, keyword: 0xFF0000FF, text: T.text
			, variable: 0xFF001080, cmdlet: 0xFF795E26, param: 0xFF5C5C5C, type: 0xFF267F99, control: 0xFFAF00DB}
	T.warn := dark ? 0xFFFCE100 : 0xFF9D5D00     ; Windows 11 "caution" colours
	T.onWarn := dark ? 0xFF1B1B1B : 0xFFFFFFFF
	T.accent := 0xFF000000 | accentRGB
	T.accentSoft := (dark ? 0x40000000 : 0x26000000) | accentRGB
	T.accentText := dark ? 0xFFFFFFFF : (0xFF000000 | accentRGB)
	T.inputBg := dark ? 0xFF1F1F1F : 0xFFFFFFFF                        ; search box (text box look)
	T.matchBg := (dark ? 0x80000000 : 0x70000000) | accentRGB           ; search matches in the preview
	CJP.T := T, CJP.themeKey := key
	return T
}

CJPanel_Hints(){
	global ini_pasteModeHints
	return (ini_pasteModeHints != "0")
}

CJPanel_HintText(){
	global paste_k, pastemodekey, TXT
	k1 := paste_k, k2 := pastemodekey.c, k3 := pastemodekey.x
	StringUpper, k1, k1
	StringUpper, k2, k2
	StringUpper, k3, k3
	d := Chr(0xB7)
	fmt := TXT.TIP_panelhint != "" ? TXT.TIP_panelhint : "{1} next  " d "  {2} back  " d "  {3} mode  " d "  release Ctrl = paste"
	return Format(fmt, k1, k2, k3)
}

; thumbnail cache: key includes mtime+size because clip numbers (and their thumbs) shift
CJPanel_GetImage(path){
	if !FileExist(path)
		return 0
	FileGetTime, mt, %path%
	FileGetSize, sz, %path%
	key := path "|" mt "|" sz
	if CJP.imgCache.HasKey(key)
		return CJP.imgCache[key].bmp
	bmp := Gdip_CreateBitmapFromFile(path)
	if (!bmp)
		return 0
	CJP.imgCache[key] := {bmp: bmp}, CJP.imgOrder.Push(key)
	while (CJP.imgOrder.Length() > 6) {
		old := CJP.imgOrder.RemoveAt(1)
		Gdip_DisposeImage(CJP.imgCache[old].bmp), CJP.imgCache.Delete(old)
	}
	return bmp
}

CJPanel_Measure(text, hFont, maxW, maxH:=0){
	CreateRectF(rc, 0, 0, maxW, maxH ? maxH : 100000)
	r := StrSplit(Gdip_MeasureString(CJP.G, text, hFont, CJP.sfWrap, rc), "|")
	return {w: Ceil(r[3]), h: Ceil(r[4])}
}

CJPanel_TextW(text, hFont){
	CreateRectF(rc, 0, 0, 100000, 1000)
	r := StrSplit(Gdip_MeasureString(CJP.G, text, hFont, CJP.sfLine, rc), "|")
	return Ceil(r[3])
}

CJPanel_Text(text, hFont, color, x, y, w, h, hFormat){
	pB := Gdip_BrushCreateSolid(color)
	CreateRectF(rc, x, y, w, h)
	Gdip_DrawString(CJP.G, text, hFont, hFormat, pB, rc)
	Gdip_DeleteBrush(pB)
}

;------------------------------------------------------------------------------------------------
; size settings ([Advanced] pasteModeWidth / pasteModeMaxLines / pasteModePreviewChars)

CJPanel_LoadSizeSettings(){
	global ini_pasteModeWidth, ini_pasteModeMaxLines
	wd := ini_pasteModeWidth, ln := ini_pasteModeMaxLines
	if wd is not integer
		wd := 480
	if ln is not integer
		ln := 12
	CJP.maxCW := Min(1600, Max(250, wd))     ; max width of the content area in px (at 100 % scaling)
	CJP.maxLines := Min(60, Max(1, ln))      ; max visible lines of a text clip
}

; how many characters of a clip are put into the preview (classic tooltip: always 200)
CJPanel_PreviewChars(){
	global ini_pasteModePreviewChars
	n := ini_pasteModePreviewChars
	if (!CJPanel_Enabled())
		return 200
	if n is not integer
		return 200
	return Min(5000, Max(50, n))
}

;------------------------------------------------------------------------------------------------
; syntax highlighter ([Advanced] pasteModeHighlight = 1 | 0)
; Display only: it colours the preview text exactly as it is shown (i.e. AFTER a previewable
; paste format such as "Join lines" / "Sentence case" was applied); the pasted data is untouched.

CJPanel_HighlightOn(){
	global ini_pasteModeHighlight
	return (ini_pasteModeHighlight != "0")
}

; returns [{t: text, c: ARGB}, ...] or "" when the text is not XML/HTML, JSON, PowerShell or JavaScript
CJPanel_Highlight(text, T){
	lead := LTrim(text, " `t`r`n")
	first := SubStr(lead, 1, 1)
	if (first = "<" && RegExMatch(lead, "^<[A-Za-z?!/]") && InStr(lead, ">"))   ; not "<#" (PowerShell block comment)
		lang := "xml"
	else if ((first = "{" || first = "[") && RegExMatch(lead, "^[\[{]\s*([""{\[\]}]|-?\d|true|false|null)"))
		lang := "json"
	else {
		ps := CJPanel_PSScore(lead), js := CJPanel_JSScore(lead)   ; both: "${x}" counts for PowerShell too
		if (js >= 2 && js > ps)
			return CJPanel_HighlightJS(text, T.hl)
		if (ps >= 2)
			return CJPanel_HighlightPS(text, T.hl)
		return ""
	}
	hl := T.hl, runs := [], pos := 1, len := StrLen(text), inTag := 0
	while (pos <= len)
	{
		if (lang = "xml") {
			if (!inTag) {
				if RegExMatch(text, "\G<!--[\s\S]*?(?:-->|$)", mt, pos)
					runs.Push({t: mt, c: hl.comment})
				else if RegExMatch(text, "\G<!\[CDATA\[[\s\S]*?(?:\]\]>|$)", mt, pos)
					runs.Push({t: mt, c: hl.string})
				else if RegExMatch(text, "\G(<[/?!]?)([\w:.\-]*)", mt, pos)
					runs.Push({t: mt1, c: hl.punct}), runs.Push({t: mt2, c: hl.tag}), inTag := 1
				else if RegExMatch(text, "\G&[#\w]+;?", mt, pos)
					runs.Push({t: mt, c: hl.entity})
				else if RegExMatch(text, "\G[^<&]+", mt, pos)
					runs.Push({t: mt, c: hl.text})
				else
					RegExMatch(text, "\G[\s\S]", mt, pos), runs.Push({t: mt, c: hl.text})
			} else {
				if RegExMatch(text, "\G\s+", mt, pos)
					runs.Push({t: mt, c: hl.text})
				else if RegExMatch(text, "\G[?/]?>", mt, pos)
					runs.Push({t: mt, c: hl.punct}), inTag := 0
				else if RegExMatch(text, "\G[\w:.\-]+", mt, pos)
					runs.Push({t: mt, c: hl.attr})
				else if RegExMatch(text, "\G(""[^""]*""?|'[^']*'?)", mt, pos)
					runs.Push({t: mt, c: hl.value})
				else
					RegExMatch(text, "\G[\s\S]", mt, pos), runs.Push({t: mt, c: hl.punct})
			}
		} else { ; json
			if RegExMatch(text, "\G""(?:[^""\\]|\\.)*""?", mt, pos)   ; string, \" escapes allowed
				runs.Push({t: mt, c: RegExMatch(text, "\G\s*:", m2, pos + StrLen(mt)) ? hl.key : hl.string})
			else if RegExMatch(text, "\G-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", mt, pos)
				runs.Push({t: mt, c: hl.number})
			else if RegExMatch(text, "\G(?:true|false|null)\b", mt, pos)
				runs.Push({t: mt, c: hl.keyword})
			else if RegExMatch(text, "\G[{}\[\],:]", mt, pos)
				runs.Push({t: mt, c: hl.punct})
			else if RegExMatch(text, "\G[^""{}\[\],:\d\-]+", mt, pos)
				runs.Push({t: mt, c: hl.text})
			else
				RegExMatch(text, "\G[\s\S]", mt, pos), runs.Push({t: mt, c: hl.text})
		}
		if (StrLen(mt) = 0)   ; safety net, must never loop forever
			mt := SubStr(text, pos, 1), runs.Push({t: mt, c: hl.text})
		pos += StrLen(mt)
	}
	return runs
}

; PowerShell detection by score, so normal prose (e.g. "Set-Up meeting for $5") is not coloured:
; cmdlet with an approved verb +1.5, each $variable +1 (max 2), block keyword +1, <# comment #> +1
CJPanel_IsPowerShell(text){
	return (CJPanel_PSScore(text) >= 2)
}

CJPanel_PSScore(text){
	static verbs := "Get|Set|New|Remove|Add|Invoke|Write|Start|Stop|Import|Export|Test|Select|Where|ForEach|Out|Format"
		. "|Convert|ConvertTo|ConvertFrom|Clear|Copy|Move|Rename|Join|Split|Read|Enable|Disable|Install|Uninstall|Update"
		. "|Register|Unregister|Measure|Sort|Group|Compare|Wait|Resolve|Push|Pop|Restart|Find|Save|Send|Connect"
		. "|Disconnect|Use|Expand|Compress|Show|Enter|Exit|Grant|Revoke|Block|Unblock|Mount|Dismount|Suspend|Resume"
		. "|Trace|Debug|Receive|Sync|Publish|Unpublish|Request|Reset|Search|Lock|Unlock|Limit|Initialize|Edit|Tee"
	t := SubStr(text, 1, 3000), score := 0
	if RegExMatch(t, "\b(" verbs ")-[A-Z][A-Za-z]+\b(\s+-[A-Za-z]+)?", mc)
		score += (mc2 != "") ? 2 : 1.5     ; cmdlet with a -Parameter (group 2; group 1 = verb) is unambiguous
	pos := 1, nv := 0
	; ${x} counts only when the text has no JavaScript template literal (`... ${x} ...`)
	varRe := RegExMatch(t, "``[^``\r\n]*\$\{") ? "\$[A-Za-z_][\w]*" : "\$(?:[A-Za-z_][\w]*|\{[^}]+\})"
	while (nv < 2 && (pos := RegExMatch(t, varRe, m, pos))) {
		nv++, pos += StrLen(m)
	}
	score += nv
	if RegExMatch(t, "im)^\s*(param\s*\(|function\s+[\w-]+|foreach\s*\(|if\s*\(.*\)\s*\{|try\s*\{|\[CmdletBinding)")
		score += 1
	if InStr(t, "<#")
		score += 1
	return score
}

; JavaScript / TypeScript detection by score (>= 2), so prose with a "function" or "=>" is not coloured:
; function declaration +2, const/let/var assignment +1.5, arrow function +1, console./document./window. +1,
; import ... from / require( / export +1.5, lines ending with ";" (2+) +0.5, // comment line +0.5
CJPanel_JSScore(text){
	t := SubStr(text, 1, 3000), score := 0
	if RegExMatch(t, "m)(^|[\s;{(=])(async\s+)?function\s*\*?\s*[\w$]*\s*\([^)]*\)\s*\{")
		score += 2
	if RegExMatch(t, "m)(^|[\s;{(])(const|let|var)\s+[\w$\[\]{},\s]+\s*=")
		score += 1.5
	if RegExMatch(t, "(\([^()]*\)|\b[\w$]+)\s*=>")
		score += 1
	if RegExMatch(t, "\b(console\.(log|warn|error|info)|document\.|window\.|JSON\.(parse|stringify)|Math\.|\.addEventListener)\s*\(?")
		score += 1
	if RegExMatch(t, "m)^\s*(import\s+.+\s+from\s+['""]|import\s+['""]|export\s+(default\s+|const\s|function\s|class\s)|.*\brequire\(\s*['""])")
		score += 1.5
	semi := 0, pos := 1
	while (semi < 2 && (pos := RegExMatch(t, "m);[ \t]*(//.*)?\r?$", m, pos)))
		semi++, pos += Max(StrLen(m), 1)
	if (semi >= 2)
		score += 0.5
	if RegExMatch(t, "m)^\s*//")
		score += 0.5
	return score
}

; JavaScript / TypeScript: comments, strings (incl. `template ${...}`), numbers, keywords, calls, types
CJPanel_HighlightJS(text, hl){
	static kw := "|const|let|var|function|class|extends|new|this|super|typeof|instanceof|in|of|void|delete|true|false"
		. "|null|undefined|NaN|Infinity|get|set|static|async|interface|type|enum|implements|public|private|protected"
		. "|readonly|declare|namespace|abstract|"
	static ctl := "|if|else|for|while|do|switch|case|default|break|continue|return|try|catch|finally|throw|await"
		. "|yield|import|export|from|as|"
	runs := [], pos := 1, len := StrLen(text), last := ""   ; last = last significant token (regex vs. division)
	while (pos <= len)
	{
		sig := 1
		if RegExMatch(text, "\G//[^\r\n]*", mt, pos)
			runs.Push({t: mt, c: hl.comment}), sig := 0
		else if RegExMatch(text, "\G/\*[\s\S]*?(?:\*/|$)", mt, pos)
			runs.Push({t: mt, c: hl.comment}), sig := 0
		else if RegExMatch(text, "\G""(?:[^""\\\r\n]|\\.)*""?", mt, pos)
			runs.Push({t: mt, c: hl.string})
		else if RegExMatch(text, "\G'(?:[^'\\\r\n]|\\.)*'?", mt, pos)
			runs.Push({t: mt, c: hl.string})
		else if RegExMatch(text, "\G``(?:[^``\\]|\\[\s\S])*``?", mt, pos)            ; template literal
			CJPanel_HighlightJSTemplate(mt, runs, hl)
		else if (!RegExMatch(last, "[\w$)\]]$") && RegExMatch(text, "\G/(?![/*])(?:[^/\\\r\n\[]|\\.|\[(?:[^\]\\\r\n]|\\.)*\])+/[gimsuyd]*", mt, pos))
			runs.Push({t: mt, c: hl.string})                                         ; /regex/
		else if RegExMatch(text, "\G(?:0[xX][\da-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)n?\b", mt, pos)
			runs.Push({t: mt, c: hl.number})
		else if RegExMatch(text, "\G[A-Za-z_$][\w$]*", mt, pos) {
			if InStr(ctl, "|" mt "|")
				cl := hl.control
			else if InStr(kw, "|" mt "|")
				cl := hl.keyword
			else if RegExMatch(text, "\G\s*\(", m2, pos + StrLen(mt))             ; call / declaration
				cl := hl.cmdlet
			else if RegExMatch(mt, "^[A-Z][a-z]\w*$")                                 ; ClassName
				cl := hl.type
			else
				cl := hl.variable
			runs.Push({t: mt, c: cl})
		}
		else if RegExMatch(text, "\G\s+", mt, pos)
			runs.Push({t: mt, c: hl.text}), sig := 0
		else
			RegExMatch(text, "\G[\s\S]", mt, pos), runs.Push({t: mt, c: hl.text})
		if (StrLen(mt) = 0)
			mt := SubStr(text, pos, 1), runs.Push({t: mt, c: hl.text})
		if sig
			last := mt
		pos += StrLen(mt)
	}
	return runs
}

; `text ${expr} text`: the string in string colour, ${ } as punctuation, the expression as variable
CJPanel_HighlightJSTemplate(s, runs, hl){
	pos := 1, len := StrLen(s)
	while (pos <= len)
	{
		if RegExMatch(s, "\G\$\{([^}]*)(\}?)", mt, pos)
			runs.Push({t: "${", c: hl.keyword}), runs.Push({t: mt1, c: hl.variable}), runs.Push({t: mt2, c: hl.keyword})
		else if RegExMatch(s, "\G(?:[^$\\]|\\[\s\S]|\$(?!\{))+", mt, pos)
			runs.Push({t: mt, c: hl.string})
		else
			RegExMatch(s, "\G[\s\S]", mt, pos), runs.Push({t: mt, c: hl.string})
		if (StrLen(mt) = 0)
			mt := SubStr(s, pos, 1), runs.Push({t: mt, c: hl.string})
		pos += StrLen(mt)
	}
}

CJPanel_HighlightPS(text, hl){
	static kw := "|if|else|elseif|foreach|for|while|do|until|switch|function|filter|param|begin|process|end|return|break"
		. "|continue|try|catch|finally|throw|trap|in|class|enum|using|exit|dynamicparam|workflow|data|"
	static ops := "|eq|ne|gt|ge|lt|le|like|notlike|match|notmatch|contains|notcontains|in|notin|replace|and|or|not|xor"
		. "|band|bor|bxor|bnot|is|isnot|as|f|split|join|ceq|cne|clike|cmatch|creplace|ieq|ilike|imatch|"
	runs := [], pos := 1, len := StrLen(text)
	while (pos <= len)
	{
		prev := pos > 1 ? SubStr(text, pos - 1, 1) : " "
		if RegExMatch(text, "\G<#[\s\S]*?(?:#>|$)", mt, pos)
			runs.Push({t: mt, c: hl.comment})
		else if RegExMatch(text, "\G#[^\r\n]*", mt, pos)
			runs.Push({t: mt, c: hl.comment})
		else if RegExMatch(text, "\G@(""[\s\S]*?(?:\n""@|$)|'[\s\S]*?(?:\n'@|$))", mt, pos)     ; here-strings
			runs.Push({t: mt, c: hl.string})
		else if RegExMatch(text, "\G""(?:[^""``]|``[\s\S]|"""")*""?", mt, pos)            ; "..." with `escapes / ""
			runs.Push({t: mt, c: hl.string})
		else if RegExMatch(text, "\G'(?:[^']|'')*'?", mt, pos)
			runs.Push({t: mt, c: hl.string})
		else if RegExMatch(text, "\G\$(?:\{[^}]*\}?|[\w:]+|[?^$_])", mt, pos)
			runs.Push({t: mt, c: hl.variable})
		else if RegExMatch(text, "\G\[[A-Za-z_][\w.]*(?:\[\])?\]", mt, pos)                   ; [type]
			runs.Push({t: mt, c: hl.type})
		else if (InStr(" `t`r`n(|{;,=", prev) && RegExMatch(text, "\G-[A-Za-z][\w]*", mt, pos))   ; -Param / -eq
			runs.Push({t: mt, c: InStr(ops, "|" SubStr(mt, 2) "|") ? hl.control : hl.param})
		else if RegExMatch(text, "\G\d+(?:\.\d+)?(?:[kmgtp]b)?\b", mt, pos)
			runs.Push({t: mt, c: hl.number})
		else if RegExMatch(text, "\G[A-Za-z_][\w]*(?:-[A-Za-z][\w]*)*", mt, pos) {          ; words, Verb-Noun
			if InStr(mt, "-")
				cl := hl.cmdlet
			else if InStr(kw, "|" mt "|")
				cl := hl.control
			else
				cl := hl.text
			runs.Push({t: mt, c: cl})
		}
		else if RegExMatch(text, "\G[\s]+", mt, pos)
			runs.Push({t: mt, c: hl.text})
		else                ; operators/braces in normal text colour (the XML punct colour looks odd here)
			RegExMatch(text, "\G[\s\S]", mt, pos), runs.Push({t: mt, c: hl.text})
		if (StrLen(mt) = 0)
			mt := SubStr(text, pos, 1), runs.Push({t: mt, c: hl.text})
		pos += StrLen(mt)
	}
	return runs
}

; wraps coloured runs into lines: breaks at spaces, newlines and - for long tokens such as
; paths or URLs - inside the token. Returns {lines: [[{t, c, x, w}]], w, h, lineH}
CJPanel_Layout(runs, maxW, maxLines, lineH){
	lines := [[]], px := 0, wMax := 0, cut := 0
	for i, run in runs
	{
		fnt := CJPanel_BodyFont(run.st)
		for j, seg in StrSplit(run.t, "`n", "`r")
		{
			if (j > 1) {   ; newline inside the run
				wMax := Max(wMax, px), px := 0
				if (lines.Length() >= maxLines) {
					cut := 1
					break 2
				}
				lines.Push([])
			}
			seg := StrReplace(seg, "`t", "    ")
			p := 1
			while RegExMatch(seg, "\G(\S+\s*|\s+)", ck, p)
			{
				p += StrLen(ck)
				cw := CJPanel_TextWT(ck, fnt)
				if (px + cw <= maxW) {
					lines[lines.Length()].Push({t: ck, c: run.c, bg: run.bg, st: run.st, x: px, w: cw}), px += cw
					continue
				}
				if (px > 0 && CJPanel_TextWT(RTrim(ck), fnt) <= maxW) {   ; fits on a fresh line
					wMax := Max(wMax, px), px := 0
					if (lines.Length() >= maxLines) {
						cut := 1
						break 3
					}
					lines.Push([])
					lines[lines.Length()].Push({t: ck, c: run.c, bg: run.bg, st: run.st, x: 0, w: cw}), px := cw
					continue
				}
				; token longer than the free space: split it by characters
				rest := ck
				while (rest != "")
				{
					n := CJPanel_FitChars(rest, maxW - px, fnt)
					if (n = 0 && px = 0)
						n := 1
					if (n > 0) {
						part := SubStr(rest, 1, n), pw := CJPanel_TextWT(part, fnt)
						lines[lines.Length()].Push({t: part, c: run.c, bg: run.bg, st: run.st, x: px, w: pw}), px += pw
						rest := SubStr(rest, n + 1)
					}
					if (rest != "") {
						wMax := Max(wMax, px), px := 0
						if (lines.Length() >= maxLines) {
							cut := 1
							break 4
						}
						lines.Push([])
					}
				}
			}
		}
	}
	wMax := Max(wMax, px)
	if (cut) {   ; mark truncation with an ellipsis at the end of the last line
		ell := " " Chr(0x2026), ew := CJPanel_TextWT(ell, CJP.fBody)
		last := lines[lines.Length()]
		while (last.Length() && last[last.Length()].x + last[last.Length()].w > maxW - ew)
			last.Pop()
		ex := last.Length() ? last[last.Length()].x + last[last.Length()].w : 0
		last.Push({t: ell, c: CJP.T.text3, x: ex, w: ew})
		wMax := Max(wMax, ex + ew)
	}
	return {lines: lines, w: Ceil(wMax), h: Ceil(lines.Length() * lineH), lineH: lineH}
}

; splits coloured runs at the matches of the search words (space separated, case-insensitive,
; like SuperInstr in the search) and gives the matched pieces a background
CJPanel_MarkRuns(runs, query, T){
	words := []
	for k, wd in StrSplit(Trim(query), " ")
		if (wd != "")
			words.Push(wd)
	if !words.Length()
		return runs
	out := []
	for i, run in runs
	{
		s := run.t, pos := 1, len := StrLen(s)
		while (pos <= len)
		{
			best := 0, bestLen := 0     ; earliest (then longest) match of any word from pos
			for k, wd in words
				if ((p := InStr(s, wd, false, pos)) && (!best || p < best || (p = best && StrLen(wd) > bestLen)))
					best := p, bestLen := StrLen(wd)
			if (!best) {
				out.Push({t: SubStr(s, pos), c: run.c, st: run.st})
				break
			}
			if (best > pos)
				out.Push({t: SubStr(s, pos, best - pos), c: run.c, st: run.st})
			out.Push({t: SubStr(s, best, bestLen), c: T.text, bg: T.matchBg, st: run.st})
			pos := best + bestLen
		}
	}
	return out
}

; search box of the paste mode panel: magnifier, query + caret, "3 / 12" (or "no matches"), accent underline
; srch: {query, cur, total, placeholder, none}
CJPanel_SearchBox(G, T, srch, px, py, pw, ph){
	scl := CJP.scale, R := Round(4*scl)
	pB := Gdip_BrushCreateSolid(T.border)
	Gdip_FillRoundedRectanglePath(G, pB, px, py, pw, ph, R)
	Gdip_DeleteBrush(pB)
	pB := Gdip_BrushCreateSolid(T.inputBg)
	Gdip_FillRoundedRectanglePath(G, pB, px + 1, py + 1, pw - 2, ph - 2, R - 1)
	Gdip_DeleteBrush(pB)
	; focused text box (Windows 11): accent line at the bottom, clipped to the rounded box
	pPath := Gdip_CreatePath()
	Gdip_AddPathRoundedRectangle(pPath, px, py, pw, ph, R)
	Gdip_SetClipPath(G, pPath)
	pB := Gdip_BrushCreateSolid(T.accent)
	Gdip_FillRectangle(G, pB, px, py + ph - Round(2*scl), pw, Round(2*scl))
	Gdip_DeleteBrush(pB)
	Gdip_ResetClip(G)
	Gdip_DeletePath(pPath)

	; magnifier
	ic := Round(14*scl), ix := px + Round(10*scl), iy := py + (ph - ic)//2 - Round(1*scl)
	r := ic * 0.36, cxm := ix + r + 1, cym := iy + r + 1
	pP := Gdip_CreatePen(T.text2, 1.6*scl)
	Gdip_DrawEllipse(G, pP, cxm - r, cym - r, 2*r, 2*r)
	Gdip_DrawLine(G, pP, cxm + r*0.72, cym + r*0.72, ix + ic - 1, iy + ic - 1)
	Gdip_DeletePen(pP)

	; counter on the right
	q := srch.query, tx := ix + ic + Round(10*scl), lh := Round(20*scl), ty := py + (ph - lh)//2 - Round(1*scl)
	if (q = "")
		cnt := "", cntCol := T.text2
	else if (srch.total > 0)
		cnt := srch.cur " / " srch.total, cntCol := T.text2
	else
		cnt := srch.none, cntCol := T.warn
	cntW := cnt != "" ? CJPanel_TextW(cnt, CJP.fMeta) : 0
	if (cnt != "")
		CJPanel_Text(cnt, CJP.fMeta, cntCol, px, ty + Round(1*scl), pw - Round(10*scl), lh, CJP.sfRight)

	; query (its end stays visible) + caret, or the placeholder
	avail := pw - (tx - px) - Round(10*scl) - (cntW ? cntW + Round(12*scl) : 0) - Round(4*scl)
	if (q = "") {
		CJPanel_Text(srch.placeholder, CJP.fList, T.text3, tx, ty, avail, lh, CJP.sfLine)
		qw := 0
	} else {
		shown := q, ell := Chr(0x2026)
		while (StrLen(shown) > 1 && CJPanel_TextWT(shown, CJP.fList) > avail)
			shown := SubStr(shown, 2)
		if (shown != q)
			shown := ell SubStr(shown, 2)
		CJPanel_Text(shown, CJP.fList, T.text, tx, ty, avail + 4, lh, CJP.sfTypo)
		qw := CJPanel_TextWT(shown, CJP.fList)
	}
	pB := Gdip_BrushCreateSolid(T.text)
	Gdip_FillRectangle(G, pB, tx + qw + Round(1*scl), py + Round(8*scl), Max(1, Round(1*scl)), ph - Round(16*scl))
	Gdip_DeleteBrush(pB)
}

; how many leading characters of str fit into avail px (binary search)
CJPanel_FitChars(str, avail, fnt := ""){
	if !fnt
		fnt := CJP.fBody
	lo := 0, hi := StrLen(str)
	while (lo < hi) {
		mid := (lo + hi + 1) // 2
		if (CJPanel_TextWT(SubStr(str, 1, mid), fnt) <= avail)
			lo := mid
		else
			hi := mid - 1
	}
	return lo
}

CJPanel_DrawLayout(G, lay, px, py){
	brushes := {}
	for i, line in lay.lines     ; backgrounds first (search matches), so the text stays on top
		for j, pc in line
			if (pc.bg) {
				if !brushes.HasKey(pc.bg)
					brushes[pc.bg] := Gdip_BrushCreateSolid(pc.bg)
				Gdip_FillRoundedRectanglePath(G, brushes[pc.bg], px + pc.x - 1, py + (i-1)*lay.lineH + 1
					, pc.w + 2, lay.lineH - 1, Round(3*CJP.scale))
			}
	for i, line in lay.lines
		for j, pc in line {
			if !brushes.HasKey(pc.c)
				brushes[pc.c] := Gdip_BrushCreateSolid(pc.c)
			CreateRectF(rc, px + pc.x, py + (i-1)*lay.lineH, pc.w + 4, lay.lineH + 2)
			Gdip_DrawString(G, pc.t, CJPanel_BodyFont(pc.st), CJP.sfTypo, brushes[pc.c], rc)
		}
	for k, pB in brushes
		Gdip_DeleteBrush(pB)
}

; exact (typographic, no padding) width; trailing spaces included
CJPanel_TextWT(text, hFont){
	CreateRectF(rc, 0, 0, 100000, 1000)
	r := StrSplit(Gdip_MeasureString(CJP.G, text, hFont, CJP.sfTypo, rc), "|")
	return r[3] + 0
}

;------------------------------------------------------------------------------------------------
; rich formats of the clip currently on the clipboard (paste mode loads the clip there):
; returns {kind: "HTML" | "Link" | "Rich Text" | "", url, text, html (CF_HTML when it is not a single link)}
;   Link = the HTML fragment is a single hyperlink -> url is shown below the preview

CJPanel_ClipRichInfo(){
	static cfHTML := DllCall("RegisterClipboardFormat", "Str", "HTML Format", "UInt")
	static cfRTF := DllCall("RegisterClipboardFormat", "Str", "Rich Text Format", "UInt")
	res := {kind: "", url: "", text: "", html: ""}
	; Word/Outlook/WordPad supply RTF (often plus HTML), browsers HTML only -> RTF wins over HTML,
	; a single hyperlink wins over both
	hasRTF := DllCall("IsClipboardFormatAvailable", "UInt", cfRTF)
	if hasRTF
		res.kind := "Rich Text"
	if DllCall("IsClipboardFormatAvailable", "UInt", cfHTML) {
		if !hasRTF
			res.kind := "HTML"
		html := ""
		loop 5 {   ; the clipboard may be busy for a moment
			if DllCall("OpenClipboard", "Ptr", 0) {
				if (hMem := DllCall("GetClipboardData", "UInt", cfHTML, "Ptr")) {
					size := DllCall("GlobalSize", "Ptr", hMem, "UPtr")
					if (size && size < 2000000 && (pMem := DllCall("GlobalLock", "Ptr", hMem, "Ptr"))) {
						html := StrGet(pMem, size, "UTF-8")
						DllCall("GlobalUnlock", "Ptr", hMem)
					}
				}
				DllCall("CloseClipboard")
				break
			}
			Sleep, 5
		}
		if IsObject(lk := CJPanel_ParseHtmlLink(html))
			res.kind := "Link", res.url := lk.url, res.text := lk.text
		else
			res.html := html
	}
	return res
}

; CF_HTML data -> {url, text} when its fragment is exactly one hyperlink (plus markup/whitespace), else ""
CJPanel_ParseHtmlLink(html){
	frag := html
	if (p1 := InStr(html, "<!--StartFragment-->")) && (p2 := InStr(html, "<!--EndFragment-->", false, p1))
		frag := SubStr(html, p1 + 20, p2 - p1 - 20)
	if (StrLen(frag) >= 20000)
		return ""
	if !RegExMatch(frag, "Ois)<a\b[^>]*?\bhref\s*=\s*(""([^""]*)""|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>", m)
		return ""
	rest := SubStr(frag, m.Pos(0) + m.Len(0))
	if RegExMatch(rest, "i)<a\b[^>]*\bhref")     ; more than one link
		return ""
	outside := RegExReplace(SubStr(frag, 1, m.Pos(0) - 1) rest, "s)<[^>]*>|&nbsp;|\s")
	if (outside != "")                           ; there is other text around the link
		return ""
	return {url: CJPanel_HtmlDecode(m.Value(2) m.Value(3) m.Value(4))
		, text: Trim(CJPanel_HtmlDecode(RegExReplace(m.Value(5), "s)<[^>]*>")))}
}

CJPanel_HtmlDecode(s){
	s := StrReplace(s, "&quot;", """"), s := StrReplace(s, "&#39;", "'"), s := StrReplace(s, "&apos;", "'")
	s := StrReplace(s, "&lt;", "<"), s := StrReplace(s, "&gt;", ">"), s := StrReplace(s, "&nbsp;", " ")
	pos := 1     ; numeric entities (&#160; from VS Code, &#x2014; ...); "&amp;" last, so "&amp;#160;" stays text
	while (pos := RegExMatch(s, "&#(x[0-9A-Fa-f]{1,6}|\d{1,7});", m, pos)) {
		n := SubStr(m1, 1, 1) = "x" ? CJPanel_Hex(SubStr(m1, 2)) : m1 + 0
		ch := (n = 160) ? " " : (n > 0 && n < 0x110000) ? Chr(n) : ""
		s := SubStr(s, 1, pos - 1) ch SubStr(s, pos + StrLen(m)), pos += StrLen(ch)
	}
	return StrReplace(s, "&amp;", "&")
}

;------------------------------------------------------------------------------------------------
; formatted preview of rich clips ([Advanced] pasteModeRichText = 1 | 0)

CJPanel_RichOn(){
	global ini_pasteModeRichText
	return (ini_pasteModeRichText != "0")
}

; body font with style bits 1 = bold, 2 = italic, 4 = underline (cached, freed with the fonts)
CJPanel_BodyFont(st){
	if !st
		return CJP.fBody
	if !CJP.fBodyV.HasKey(st)
		CJP.fBodyV[st] := Gdip_FontCreate(CJP.famBody, CJP.bodyPx, st, 2)
	return CJP.fBodyV[st]
}

; CF_HTML (Word, Outlook, browsers, VS Code) -> [{t, c, st}] or "" when the fragment has no visible
; formatting (then the plain text / syntax highlighting is shown). Colours are made readable on the
; panel background; backgrounds and font sizes are ignored.
CJPanel_HtmlRuns(html, T){
	static blocks := "|p|div|li|ul|ol|tr|table|h1|h2|h3|h4|h5|h6|pre|blockquote|section|article|header|footer|dd|dt|dl|hr|"
	static voids := "|img|hr|meta|link|input|col|wbr|area|base|source|"
	frag := html
	if (p1 := InStr(html, "<!--StartFragment-->")) && (p2 := InStr(html, "<!--EndFragment-->", false, p1))
		frag := SubStr(html, p1 + 20, p2 - p1 - 20)
	else
		frag := RegExReplace(html, "s)^Version:.*?(?=<)")
	if (StrLen(frag) > 400000)
		frag := SubStr(frag, 1, 400000)
	rules := {}, sp := 1     ; CSS rules of <style> blocks (Word: heading colours, character styles)
	while (sp := RegExMatch(html, "is)<style\b[^>]*>(.*?)</style>", sm, sp))
		CJPanel_CssRules(sm1, rules), sp += StrLen(sm)
	frag := RegExReplace(frag, "is)<(script|style|head|title|xml)\b.*?</\1\s*>")
	frag := RegExReplace(frag, "s)<!--.*?-->")
	stack := [{tag: "", st: 0, c: "", pre: 0, list: ""}], runs := [], pos := 1, len := StrLen(frag)
	out := {n: 0, nl: 1, sp: 0, styled: 0}
	while (pos <= len && out.n < 6000)
	{
		if RegExMatch(frag, "\G<[!?][^>]*>", m, pos) {             ; <![if ...]>, <?xml ...?>
			pos += StrLen(m)
			continue
		}
		if RegExMatch(frag, "\G<(/?)([A-Za-z][\w:.-]*)((?:[^>""']|""[^""]*""|'[^']*')*)>", m, pos) {
			pos += StrLen(m)
			tag := RegExReplace(Format("{:L}", m2), "^\w+:")       ; <o:p> -> p
			isClose := (m1 = "/"), attrs := m3
			if (tag = "br") {
				CJPanel_HtmlEmit(runs, out, "`n", stack[stack.Length()], T)
				continue
			}
			if (InStr(blocks, "|" tag "|") && !out.nl && runs.Length())
				CJPanel_HtmlEmit(runs, out, "`n", stack[stack.Length()], T)
			if (!isClose && (tag = "td" || tag = "th") && !out.nl && runs.Length())
				CJPanel_HtmlEmit(runs, out, "   ", stack[stack.Length()], T)
			if isClose {
				i := stack.Length()
				while (i > 1 && stack[i].tag != tag)
					i--
				if (i > 1)
					while (stack.Length() >= i)
						stack.Pop()
				continue
			}
			if (InStr(voids, "|" tag "|") || RegExMatch(attrs, "/\s*$"))
				continue
			top := stack[stack.Length()]
			el := {tag: tag, st: top.st, c: top.c, pre: top.pre, list: top.list, n: 0}
			if tag in b,strong,th,h1,h2,h3,h4,h5,h6
				el.st |= 1
			if tag in i,em,cite,var,dfn
				el.st |= 2
			if tag in u,ins
				el.st |= 4
			if (tag = "pre")
				el.pre := 1
			if (tag = "ul" || tag = "ol")
				el.list := tag
			if (tag = "a" && RegExMatch(attrs, "i)\bhref\s*="))
				el.st |= 4, el.c := "link"
			if (tag = "font" && RegExMatch(attrs, "i)\bcolor\s*=\s*[""']?([#\w]+)", mc))
				el.c := CJPanel_CssColor(mc1, el.c)
			if (rules.Count()) {     ; order: tag, .class, tag.class, then the inline style
				if rules.HasKey(tag)
					CJPanel_HtmlStyle(rules[tag], el)
				if RegExMatch(attrs, "i)\bclass\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s>]+))", mcl)
					for k, cl in StrSplit(Format("{:L}", mcl1 mcl2 mcl3), " ")
						for k2, key in ["." cl, tag "." cl]
							if (cl != "" && rules.HasKey(key))
								CJPanel_HtmlStyle(rules[key], el)
			}
			if RegExMatch(attrs, "i)\bstyle\s*=\s*(""([^""]*)""|'([^']*)')", ms)
				CJPanel_HtmlStyle(ms2 ms3, el)
			stack.Push(el)
			if (tag = "li") {
				lst := 0, k := stack.Length() - 1
				while (k > 1 && !lst)
					lst := (stack[k].tag = "ul" || stack[k].tag = "ol") ? k : 0, k--
				if (lst && stack[lst].tag = "ol")
					stack[lst].n++, mark := stack[lst].n ". "
				else
					mark := Chr(0x2022) " "
				CJPanel_HtmlEmit(runs, out, mark, {st: 0, c: ""}, T)
			}
			continue
		}
		if RegExMatch(frag, "\G[^<]+", m, pos) {
			pos += StrLen(m)
			top := stack[stack.Length()]
			piece := CJPanel_HtmlDecode(m)
			if !top.pre {
				piece := RegExReplace(piece, "[ \t\r\n]+", " ")
				if (out.nl || out.sp)
					piece := LTrim(piece, " ")
			} else
				piece := StrReplace(piece, "`r")
			if (piece != "")
				CJPanel_HtmlEmit(runs, out, piece, top, T)
			continue
		}
		CJPanel_HtmlEmit(runs, out, "<", stack[stack.Length()], T), pos++
	}
	while (runs.Length() && RegExMatch(runs[runs.Length()].t, "^\s*$"))
		runs.Pop()
	if (runs.Length())
		runs[runs.Length()].t := RTrim(runs[runs.Length()].t, " `n")
	return (out.styled && runs.Length()) ? runs : ""
}

; adds text with the style of the element; merges it with the previous run when the style is the same
CJPanel_HtmlEmit(runs, out, piece, el, T){
	if (piece = "`n" && out.nl && runs.Length() && SubStr(runs[runs.Length()].t, -1) = "`n`n")
		return                                                   ; at most one empty line
	c := (el.c = "link") ? T.accentText : (el.c != "" ? CJPanel_Readable(el.c, T) : T.text)
	st := el.st ? el.st : 0
	if ((st || c != T.text) && Trim(piece) != "")
		out.styled := 1
	last := runs.Length() ? runs[runs.Length()] : ""
	if (IsObject(last) && last.c = c && last.st = st)
		last.t .= piece
	else
		runs.Push({t: piece, c: c, st: st})
	out.n += StrLen(piece), out.nl := (SubStr(piece, 0) = "`n"), out.sp := (SubStr(piece, 0) = " ")
}

; simple CSS rules ("h3", ".cls", "span.cls", comma lists) -> rules[selector] .= declarations;
; @-rules, pseudo classes and combinators are skipped
CJPanel_CssRules(css, rules){
	css := RegExReplace(css, "s)/\*.*?\*/"), css := StrReplace(StrReplace(css, "<!--"), "-->")
	pos := 1
	while (pos := RegExMatch(css, "([^{}]+)\{([^{}]*)\}", m, pos)) {
		pos += StrLen(m)
		for k, sel in StrSplit(m1, ",")
		{
			sel := Format("{:L}", Trim(sel, " `t`r`n"))
			if (sel != "" && RegExMatch(sel, "^[a-z][\w]*(\.[\w-]+)?$|^\.[\w-]+$"))
				rules[sel] := (rules.HasKey(sel) ? rules[sel] ";" : "") m2
		}
	}
}

; inline CSS: color, font-weight, font-style, text-decoration
CJPanel_HtmlStyle(css, el){
	if RegExMatch(css, "i)(?:^|;)\s*color\s*:\s*([^;]+)", m)
		el.c := CJPanel_CssColor(Trim(m1), el.c)
	if RegExMatch(css, "i)font-weight\s*:\s*(\w+)", m)
		el.st := (m1 = "bold" || m1 = "bolder" || (m1 + 0 >= 600)) ? el.st | 1 : el.st & ~1
	if RegExMatch(css, "i)font-style\s*:\s*(\w+)", m)
		el.st := (m1 = "italic" || m1 = "oblique") ? el.st | 2 : el.st & ~2
	if RegExMatch(css, "i)white-space\s*:\s*(pre|break-spaces)")     ; VS Code: indentation kept
		el.pre := 1
	if RegExMatch(css, "i)text-decoration(?:-line)?\s*:\s*([^;]+)", m)
		el.st := InStr(m1, "underline") ? el.st | 4 : (InStr(m1, "none") ? el.st & ~4 : el.st)
}

; CSS colour -> 0xRRGGBB, "" for the default text colour (black / windowtext / auto / inherit), else old
CJPanel_CssColor(v, old){
	static names := {red: 0xFF0000, green: 0x008000, blue: 0x0000FF, navy: 0x000080, maroon: 0x800000
		, purple: 0x800080, teal: 0x008080, olive: 0x808000, gray: 0x808080, grey: 0x808080, silver: 0xC0C0C0
		, orange: 0xFFA500, fuchsia: 0xFF00FF, lime: 0x00FF00, aqua: 0x00FFFF, yellow: 0xFFFF00, white: 0xFFFFFF}
	v := Trim(RegExReplace(Format("{:L}", v), "\s*!important"))
	v := RegExReplace(v, "\s+")
	if v in black,windowtext,auto,inherit,initial,currentcolor,#000,#000000,text,buttontext
		return ""
	if (v = "rgb(0,0,0)")
		return ""
	if RegExMatch(v, "^#([0-9a-f])([0-9a-f])([0-9a-f])$", m)
		return CJPanel_Hex(m1 m1 m2 m2 m3 m3)
	if RegExMatch(v, "^#([0-9a-f]{6})", m)
		return CJPanel_Hex(m1)
	if RegExMatch(v, "^rgba?\((\d+),(\d+),(\d+)", m)
		return (m1 << 16) | (m2 << 8) | m3
	if names.HasKey(v)
		return names[v]
	return old
}

; hex digits -> number ("0x" h + 0 in an expression gives "" in AHK v1)
CJPanel_Hex(h){
	h := "0x" h
	h += 0
	return h
}

; source colour -> ARGB with enough contrast to the panel background (dark text in dark mode etc.);
; greys near the theme text colour become the theme text colour
CJPanel_Readable(rgb, T){
	static cache := {}
	key := rgb "|" T.bg
	if cache.HasKey(key)
		return cache[key]
	bg := T.bg & 0xFFFFFF, lb := CJPanel_Lum(bg), dark := lb < 0.4
	r := (rgb >> 16) & 255, g := (rgb >> 8) & 255, b := rgb & 255
	if (Max(r, g, b) - Min(r, g, b) < 24 && (dark ? CJPanel_Lum(rgb) < 0.2 : CJPanel_Lum(rgb) > 0.6))
		return cache[key] := T.text
	res := T.text
	loop 12 {
		c := (r << 16) | (g << 8) | b, lc := CJPanel_Lum(c)
		if ((Max(lc, lb) + 0.05) / (Min(lc, lb) + 0.05) >= 3.5) {
			res := 0xFF000000 | c
			break
		}
		if dark   ; blend towards white / black
			r := Round(r + (255 - r) * 0.25), g := Round(g + (255 - g) * 0.25), b := Round(b + (255 - b) * 0.25)
		else
			r := Round(r * 0.75), g := Round(g * 0.75), b := Round(b * 0.75)
	}
	return cache[key] := res
}

; relative luminance (WCAG) of 0xRRGGBB
CJPanel_Lum(rgb){
	static wts := [0.2126, 0.7152, 0.0722]
	l := 0
	for i, sh in [16, 8, 0] {
		v := ((rgb >> sh) & 255) / 255
		v := v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
		l += wts[i] * v
	}
	return l
}
