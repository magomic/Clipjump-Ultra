/*
	CJTheme - Windows 11 look (light/dark) for Clipjump's regular windows (History, Settings, ...)

	Call CJTheme_Apply("GuiName") after all controls were added (before or after Gui Show).
	Follows the same theme setting as the paste mode panel: [Advanced] pasteModeTheme = auto|light|dark
	and is only active when pasteModeStyle != classic.

	What it does:
	  - Win11 window/control colours, accent-coloured links
	  - dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE), dark context menus (uxtheme)
	  - dark-mode themes for buttons, edits, combo boxes, list boxes, list views (+ header), scroll bars, up-downs
	  - check boxes / radios / group boxes: their themed text is always black, so in dark mode the
	    theme is removed from them and the text colour is set directly
	NOTE: AHK variable names are case-insensitive. Never use pairs like y/Y, g/G, w/W in one function.
*/

CJTheme_Enabled(){
	return CJPanel_Enabled()
}

CJTheme_IsDark(){
	global ini_pasteModeTheme
	if (ini_pasteModeTheme = "dark" || ini_pasteModeTheme = "light")
		return (ini_pasteModeTheme = "dark")
	RegRead, light, HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize, AppsUseLightTheme
	return (light = 0)
}

; RGB hex strings (for Gui Color / +c) and the accent colour
CJTheme_Colors(dark){
	RegRead, ac, HKCU\Software\Microsoft\Windows\DWM, AccentColor     ; 0xAABBGGRR
	if (ac = "")
		r := 0x00, g := 0x67, b := 0xC0
	else
		r := ac & 0xFF, g := (ac >> 8) & 0xFF, b := (ac >> 16) & 0xFF
	if (dark)
		r := r + (255-r)*0.35, g := g + (255-g)*0.35, b := b + (255-b)*0.35
	accent := Format("{:02X}{:02X}{:02X}", Round(r), Round(g), Round(b))
	if (dark)
		return {bg: "202020", ctrl: "2B2B2B", text: "FFFFFF", text2: "C8C8C8", accent: accent, sb: "2B2B2B"}
	return {bg: "F3F3F3", ctrl: "FFFFFF", text: "1B1B1B", text2: "5C5C5C", accent: accent, sb: "F3F3F3"}
}

; "RRGGBB" -> COLORREF (0x00BBGGRR)
CJTheme_Ref(rgb){
	v := "0x" rgb
	v += 0
	return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; process-wide: allow dark context menus / scroll bars (undocumented uxtheme ordinals, Win10 1903+)
CJTheme_AppMode(dark){
	static hUx := 0
	if !hUx
		hUx := DllCall("LoadLibrary", "Str", "uxtheme.dll", "Ptr")
	if !hUx
		return
	if (pSet := DllCall("GetProcAddress", "Ptr", hUx, "Ptr", 135, "Ptr"))   ; SetPreferredAppMode
		DllCall(pSet, "Int", dark ? 2 : 3)                                   ; 2 = ForceDark, 3 = ForceLight
	if (pFlush := DllCall("GetProcAddress", "Ptr", hUx, "Ptr", 136, "Ptr")) ; FlushMenuThemes
		DllCall(pFlush)
}

CJTheme_AllowDark(hwnd, dark){
	static pAllow := 0
	if !pAllow
		pAllow := DllCall("GetProcAddress", "Ptr", DllCall("LoadLibrary", "Str", "uxtheme.dll", "Ptr"), "Ptr", 133, "Ptr")
	if pAllow
		DllCall(pAllow, "Ptr", hwnd, "Int", dark)       ; AllowDarkModeForWindow
}

CJTheme_SetTheme(hwnd, name){
	if (name = "-")      ; remove visual styles completely
		return DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", " ", "Str", " ")
	return DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", name, "Ptr", 0)
}

CJTheme_Apply(guiName){
	if !CJTheme_Enabled()
		return
	dark := CJTheme_IsDark(), C := CJTheme_Colors(dark)
	Gui, %guiName%: +HwndhGui
	dhw := A_DetectHiddenWindows
	DetectHiddenWindows, On      ; the window is usually not shown yet -> its controls are hidden
	CJTheme_AppMode(dark)
	CJTheme_AllowDark(hGui, dark)
	VarSetCapacity(v, 4, 0), NumPut(dark, v, 0, "Int")
	if DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hGui, "UInt", 20, "Ptr", &v, "UInt", 4)  ; DWMWA_USE_IMMERSIVE_DARK_MODE
		DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hGui, "UInt", 19, "Ptr", &v, "UInt", 4)  ; pre-20H1 value
	Gui, %guiName%: Color, % C.bg, % C.ctrl

	newDark := CJTheme_HasDarkTheme()   ; Win11 24H2+: "DarkMode_DarkTheme" styles check boxes etc. with light text
	WinGet, ctrls, ControlListHwnd, ahk_id %hGui%
	loop, parse, ctrls, `n
	{
		hc := A_LoopField
		WinGetClass, cls, ahk_id %hc%
		CJTheme_AllowDark(hc, dark)
		if (cls = "Button") {
			ControlGet, st, Style,,, ahk_id %hc%
			kind := st & 0xF
			if (!dark)
				CJTheme_SetTheme(hc, "Explorer")
			else if (newDark)
				CJTheme_SetTheme(hc, "DarkMode_DarkTheme")
			else if (kind <= 1)                  ; push button (older Windows)
				CJTheme_SetTheme(hc, "DarkMode_Explorer")
			else                                 ; check box/radio/group box (older Windows): their themed text is black
				CJTheme_SetTheme(hc, "-")
			if (kind > 1)
				GuiControl, % guiName ": +c" C.text, % hc
		}
		else if (cls = "Edit" || cls = "ComboBox") {
			CJTheme_SetTheme(hc, dark ? "DarkMode_CFD" : "CFD")
			GuiControl, % guiName ": +c" C.text, % hc
		}
		else if (cls = "SysListView32") {
			CJTheme_SetTheme(hc, dark ? "DarkMode_Explorer" : "Explorer")
			SendMessage, 0x1001, 0, CJTheme_Ref(C.ctrl),, ahk_id %hc%     ; LVM_SETBKCOLOR
			SendMessage, 0x1026, 0, CJTheme_Ref(C.ctrl),, ahk_id %hc%     ; LVM_SETTEXTBKCOLOR
			SendMessage, 0x1024, 0, CJTheme_Ref(C.text),, ahk_id %hc%     ; LVM_SETTEXTCOLOR
			SendMessage, 0x101F, 0, 0,, ahk_id %hc%                        ; LVM_GETHEADER
			if (hHdr := ErrorLevel) {
				CJTheme_AllowDark(hHdr, dark)
				CJTheme_SetTheme(hHdr, "ItemsView")   ; dark via AllowDarkModeForWindow; text colour via custom draw below
				DllCall("SendMessage", "Ptr", hHdr, "UInt", 0x031A, "Ptr", 0, "Ptr", 0)
				if (dark)   ; header text stays dark -> recolour it via custom draw (subclassed list view)
					CJTheme_Subclass(hc, {kind: "lv", header: hHdr, text: CJTheme_Ref(C.text)})
			}
		}
		else if (cls = "ListBox") {   ; background = Gui Color's control colour; theme for the scroll bar
			CJTheme_SetTheme(hc, dark ? "DarkMode_Explorer" : "Explorer")
			GuiControl, % guiName ": +c" C.text, % hc
			ControlGet, st, Style,,, ahk_id %hc%
			if (st & 0x10)            ; created with CJTheme_ListBoxOpt(): rows are painted by CJTheme_DrawListBoxItem()
				CJTheme_OwnerDrawListBox(hGui, hc, dark, C)
		}
		else if (cls = "msctls_updown32" || cls = "SysTreeView32" || cls = "ScrollBar")
			CJTheme_SetTheme(hc, dark ? "DarkMode_Explorer" : "Explorer")
		else if (cls = "msctls_statusbar32") {
			if (dark)   ; no dark text possible -> paint it ourselves
				CJTheme_Subclass(hc, {kind: "sb", bg: CJTheme_Ref(C.sb), text: CJTheme_Ref(C.text2), line: CJTheme_Ref("3A3A3A")})
			else
				SendMessage, 0x2001, 0, CJTheme_Ref(C.sb),, ahk_id %hc%   ; SB_SETBKCOLOR
		}
		else if (cls = "msctls_hotkey32") {
			if (dark)   ; ignores themes -> remap its colours after it painted
				CJTheme_Subclass(hc, {kind: "hk", bg: CJTheme_Ref(C.ctrl)})
		}
		else if (cls = "Static")
			GuiControl, % guiName ": +c" C.text, % hc
		DllCall("SendMessage", "Ptr", hc, "UInt", 0x031A, "Ptr", 0, "Ptr", 0)  ; WM_THEMECHANGED
	}
	WinSet, Redraw,, ahk_id %hGui%
	DetectHiddenWindows, %dhw%
}

;------------------------------------------------------------------------------------------------
; owner-drawn list boxes: the selection of a plain list box is unreadable in dark mode (light bar,
; light text). Add the list box with CJTheme_ListBoxOpt() in its options; CJTheme_Apply() then
; paints its rows: theme colours, Windows 11 selection (soft background + accent bar).

; extra Gui, Add options for a ListBox ("" in classic style)
CJTheme_ListBoxOpt(){
	return CJTheme_Enabled() ? "+0x50" : ""    ; LBS_OWNERDRAWFIXED | LBS_HASSTRINGS
}

global CJTheme_LBs	; list box hwnd -> {parent, bg, sel, text, accent}

CJTheme_OwnerDrawListBox(hGui, hLB, dark, C){
	if !IsObject(CJTheme_LBs)
		CJTheme_LBs := {}
	CJTheme_LBs[hLB] := {parent: hGui, bg: CJTheme_Ref(C.ctrl), sel: CJTheme_Ref(dark ? "3D3D3D" : "E8E8E8")
		, text: CJTheme_Ref(C.text), accent: CJTheme_Ref(C.accent)}
	SendMessage, 0x1A0, 0, Round(24 * A_ScreenDPI / 96),, ahk_id %hLB%    ; LB_SETITEMHEIGHT
	WinSet, ExStyle, -0x200, ahk_id %hLB%      ; no light 3D client edge: flat like the themed list views
	DllCall("SetWindowPos", "Ptr", hLB, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020)  ; NOSIZE|NOMOVE|NOZORDER|NOACTIVATE|FRAMECHANGED
	CJTheme_Subclass(hGui, {kind: "odparent"})   ; WM_DRAWITEM goes to the parent window
	DllCall("InvalidateRect", "Ptr", hLB, "Ptr", 0, "Int", 1)
}

CJTheme_DrawListBoxItem(lParam, lb){
	o := (A_PtrSize = 8) ? 24 : 20                 ; DRAWITEMSTRUCT: hwndItem, hDC, rcItem follow
	id := NumGet(lParam+0, 8, "Int"), state := NumGet(lParam+0, 16, "UInt")
	hItem := NumGet(lParam+0, o, "Ptr"), hdc := NumGet(lParam+0, o + A_PtrSize, "Ptr")
	rc := lParam + o + 2*A_PtrSize
	l := NumGet(rc+0, 0, "Int"), t := NumGet(rc+0, 4, "Int"), r := NumGet(rc+0, 8, "Int"), b := NumGet(rc+0, 12, "Int")
	scl := A_ScreenDPI / 96
	hBr := DllCall("CreateSolidBrush", "UInt", lb.bg, "Ptr")
	DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", hBr), DllCall("DeleteObject", "Ptr", hBr)
	if (id >= 0 && (state & 0x1)) {                ; ODS_SELECTED: soft rounded background + accent bar
		oldPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", DllCall("GetStockObject", "Int", 8, "Ptr"), "Ptr")  ; NULL_PEN
		hBr := DllCall("CreateSolidBrush", "UInt", lb.sel, "Ptr")
		oldBr := DllCall("SelectObject", "Ptr", hdc, "Ptr", hBr, "Ptr")
		ins := Round(3*scl), rr := Round(8*scl)
		DllCall("RoundRect", "Ptr", hdc, "Int", l + ins, "Int", t + 1, "Int", r - ins + 1, "Int", b, "Int", rr, "Int", rr)
		DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBr), DllCall("DeleteObject", "Ptr", hBr)
		hBr := DllCall("CreateSolidBrush", "UInt", lb.accent, "Ptr")
		oldBr := DllCall("SelectObject", "Ptr", hdc, "Ptr", hBr, "Ptr")
		bh := Round(16*scl)//2*2, bw := Max(3, Round(3*scl)), my := t + (b - t)//2
		DllCall("RoundRect", "Ptr", hdc, "Int", l + ins, "Int", my - bh//2, "Int", l + ins + bw + 1, "Int", my + bh//2 + 1, "Int", bw, "Int", bw)
		DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBr), DllCall("DeleteObject", "Ptr", hBr)
		DllCall("SelectObject", "Ptr", hdc, "Ptr", oldPen)
	}
	if (id >= 0) {
		len := DllCall("SendMessage", "Ptr", hItem, "UInt", 0x18A, "Ptr", id, "Ptr", 0, "Ptr")   ; LB_GETTEXTLEN
		if (len > 0) {
			VarSetCapacity(buf, (len + 1) * 2, 0)
			DllCall("SendMessage", "Ptr", hItem, "UInt", 0x189, "Ptr", id, "Ptr", &buf)           ; LB_GETTEXT
			hFont := DllCall("SendMessage", "Ptr", hItem, "UInt", 0x31, "Ptr", 0, "Ptr", 0, "Ptr") ; WM_GETFONT
			oldFont := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
			DllCall("SetBkMode", "Ptr", hdc, "Int", 1), DllCall("SetTextColor", "Ptr", hdc, "UInt", lb.text)
			VarSetCapacity(tr, 16, 0)
			NumPut(l + Round(12*scl), tr, 0, "Int"), NumPut(t, tr, 4, "Int"), NumPut(r - Round(6*scl), tr, 8, "Int"), NumPut(b, tr, 12, "Int")
			DllCall("DrawTextW", "Ptr", hdc, "Ptr", &buf, "Int", -1, "Ptr", &tr, "UInt", 0x4 | 0x20 | 0x800 | 0x8000)  ; VCENTER|SINGLELINE|NOPREFIX|END_ELLIPSIS
			DllCall("SelectObject", "Ptr", hdc, "Ptr", oldFont)
		}
	}
	return 1
}

CJTheme_HasDarkTheme(){
	v := StrSplit(A_OSVersion, ".")
	return (v[1] >= 10 && v[3] >= 26100)
}

;------------------------------------------------------------------------------------------------
; subclassing for the controls that cannot be dark-themed by Windows itself

global CJTheme_Subs	; created on first use (an initializer here would never run: file is included after auto-execute)

CJTheme_Subclass(hwnd, info){
	static cb := RegisterCallback("CJTheme_SubProc", "Fast", 6)
	if !IsObject(CJTheme_Subs)
		CJTheme_Subs := {}
	if CJTheme_Subs.HasKey(hwnd)
		return
	CJTheme_Subs[hwnd] := info
	DllCall("comctl32\SetWindowSubclass", "Ptr", hwnd, "Ptr", cb, "UPtr", 0xC1, "UPtr", 0)
}

CJTheme_SubProc(hwnd, msg, wParam, lParam, idSub, refData){
	static cb := RegisterCallback("CJTheme_SubProc", "Fast", 6)
	info := CJTheme_Subs[hwnd]
	if (msg = 0x82) {   ; WM_NCDESTROY: clean up
		DllCall("comctl32\RemoveWindowSubclass", "Ptr", hwnd, "Ptr", cb, "UPtr", 0xC1)
		CJTheme_Subs.Delete(hwnd)
		if (info.kind = "odparent") {   ; forget the owner-drawn list boxes of this window
			gone := []
			for hLB, lb in CJTheme_LBs
				if (lb.parent = hwnd)
					gone.Push(hLB)
			for k, hLB in gone
				CJTheme_LBs.Delete(hLB)
		}
	}
	else if (info.kind = "odparent" && msg = 0x2B) {   ; WM_DRAWITEM
		if (NumGet(lParam+0, 0, "UInt") = 2                ; ODT_LISTBOX
		&& (lb := CJTheme_LBs[NumGet(lParam+0, (A_PtrSize = 8) ? 24 : 20, "Ptr")]))
			return CJTheme_DrawListBoxItem(lParam, lb)
	}
	else if (info.kind = "lv" && msg = 0x4E) {   ; WM_NOTIFY from the header
		if (NumGet(lParam+0, 0, "Ptr") = info.header && NumGet(lParam+0, 2*A_PtrSize, "Int") = -12) {   ; NM_CUSTOMDRAW
			stage := NumGet(lParam+0, 3*A_PtrSize, "UInt")
			if (stage = 1)          ; CDDS_PREPAINT
				return 0x20         ; CDRF_NOTIFYITEMDRAW
			if (stage = 0x10001) {  ; CDDS_ITEMPREPAINT
				DllCall("SetTextColor", "Ptr", NumGet(lParam+0, 4*A_PtrSize, "Ptr"), "UInt", info.text)
				return 0            ; CDRF_DODEFAULT
			}
		}
	}
	else if (info.kind = "sb" && msg = 0x0F) {   ; WM_PAINT
		CJTheme_PaintStatusBar(hwnd, info)
		return 0
	}
	else if (info.kind = "hk") {
		if (msg = 0x0F) {   ; WM_PAINT: always repaint everything (light), then remap everything (dark)
			DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
			r := DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", msg, "Ptr", wParam, "Ptr", lParam, "Ptr")
			CJTheme_RemapHotkey(hwnd, info)
			return r
		}
		; keys, focus, HKM_SETHOTKEY: the control may draw directly -> force a full (remapped) repaint
		if ((msg >= 0x100 && msg <= 0x109) || msg = 0x07 || msg = 0x08 || msg = 0x401) {
			r := DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", msg, "Ptr", wParam, "Ptr", lParam, "Ptr")
			DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1), DllCall("UpdateWindow", "Ptr", hwnd)
			return r
		}
	}
	return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", msg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

CJTheme_PaintStatusBar(hwnd, info){
	VarSetCapacity(ps, A_PtrSize = 8 ? 72 : 64, 0)
	hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", &ps, "Ptr")
	VarSetCapacity(rc, 16, 0), DllCall("GetClientRect", "Ptr", hwnd, "Ptr", &rc)
	cw := NumGet(rc, 8, "Int"), ch := NumGet(rc, 12, "Int")
	hBr := DllCall("CreateSolidBrush", "UInt", info.bg, "Ptr")
	DllCall("FillRect", "Ptr", hdc, "Ptr", &rc, "Ptr", hBr), DllCall("DeleteObject", "Ptr", hBr)
	VarSetCapacity(ln, 16, 0), NumPut(cw, ln, 8, "Int"), NumPut(1, ln, 12, "Int")
	hBr := DllCall("CreateSolidBrush", "UInt", info.line, "Ptr")
	DllCall("FillRect", "Ptr", hdc, "Ptr", &ln, "Ptr", hBr), DllCall("DeleteObject", "Ptr", hBr)
	hFont := DllCall("SendMessage", "Ptr", hwnd, "UInt", 0x31, "Ptr", 0, "Ptr", 0, "Ptr")   ; WM_GETFONT
	old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
	DllCall("SetBkMode", "Ptr", hdc, "Int", 1), DllCall("SetTextColor", "Ptr", hdc, "UInt", info.text)
	parts := DllCall("SendMessage", "Ptr", hwnd, "UInt", 0x406, "Ptr", 0, "Ptr", 0, "Ptr")  ; SB_GETPARTS (count)
	parts := Max(parts, 1)
	VarSetCapacity(edges, 4*parts, 0)
	DllCall("SendMessage", "Ptr", hwnd, "UInt", 0x406, "Ptr", parts, "Ptr", &edges)
	left := 0
	loop % parts
	{
		i := A_Index - 1
		right := NumGet(edges, 4*i, "Int")
		if (right < 0)
			right := cw
		len := DllCall("SendMessage", "Ptr", hwnd, "UInt", 0x40C, "Ptr", i, "Ptr", 0, "Ptr") & 0xFFFF  ; SB_GETTEXTLENGTHW
		VarSetCapacity(buf, (len + 1) * 2, 0)
		DllCall("SendMessage", "Ptr", hwnd, "UInt", 0x40D, "Ptr", i, "Ptr", &buf)                     ; SB_GETTEXTW
		VarSetCapacity(tr, 16, 0)
		NumPut(left + 6, tr, 0, "Int"), NumPut(1, tr, 4, "Int"), NumPut(right - 4, tr, 8, "Int"), NumPut(ch, tr, 12, "Int")
		DllCall("DrawTextW", "Ptr", hdc, "Ptr", &buf, "Int", -1, "Ptr", &tr, "UInt", 0x4 | 0x20 | 0x8000)  ; VCENTER|SINGLELINE|END_ELLIPSIS
		left := right
	}
	DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
	DllCall("EndPaint", "Ptr", hwnd, "Ptr", &ps)
}

; the hotkey control paints white/black with system colours: invert and lift to the dark control colour
CJTheme_RemapHotkey(hwnd, info){
	DllCall("HideCaret", "Ptr", hwnd)
	hdc := DllCall("GetDC", "Ptr", hwnd, "Ptr")
	VarSetCapacity(rc, 16, 0), DllCall("GetClientRect", "Ptr", hwnd, "Ptr", &rc)
	DllCall("InvertRect", "Ptr", hdc, "Ptr", &rc)
	hBr := DllCall("CreateSolidBrush", "UInt", info.bg, "Ptr")
	old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hBr, "Ptr")
	DllCall("PatBlt", "Ptr", hdc, "Int", 0, "Int", 0, "Int", NumGet(rc, 8, "Int"), "Int", NumGet(rc, 12, "Int"), "UInt", 0xFA0089)  ; DPo: dest OR brush
	DllCall("SelectObject", "Ptr", hdc, "Ptr", old), DllCall("DeleteObject", "Ptr", hBr)
	DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", hdc)
	DllCall("ShowCaret", "Ptr", hwnd)
}

; Windows menu font (the one context menus use, normally Segoe UI 9 pt): {name, size}
CJTheme_SysFont(){
	static f := ""
	if IsObject(f)
		return f
	sz := (A_IsUnicode ? 500 : 340) + 4
	VarSetCapacity(ncm, sz, 0), NumPut(sz, ncm, 0, "UInt")
	f := {name: "Segoe UI", size: 9}
	if DllCall("SystemParametersInfo", "UInt", 0x29, "UInt", sz, "Ptr", &ncm, "UInt", 0) {   ; SPI_GETNONCLIENTMETRICS
		lf := 224                                                     ; offset of lfMenuFont (LOGFONTW)
		ht := NumGet(ncm, lf, "Int")
		nm := StrGet(&ncm + lf + 28, 32, "UTF-16")
		if (nm != "")
			f.name := nm
		if (ht)
			f.size := Round(Abs(ht) * 72 / A_ScreenDPI)
	}
	return f
}

; Gui, Font options/name of the system font (for getControlInfo() measurements); "" in classic style
CJTheme_FontOpt(more := ""){
	return CJTheme_Enabled() ? Trim("s" CJTheme_SysFont().size " " more) : more
}
CJTheme_FontName(){
	return CJTheme_Enabled() ? CJTheme_SysFont().name : ""
}

; set the system font as the GUI's current font - call right after Gui New, before adding controls
CJTheme_GuiFont(guiName){
	if !CJTheme_Enabled()
		return
	f := CJTheme_SysFont()
	Gui, %guiName%: Font, % "s" f.size " norm", % f.name
}

; colour a link-like Text control (call after CJTheme_Apply)
CJTheme_Link(guiName, ctrl){
	if !CJTheme_Enabled()
		return
	C := CJTheme_Colors(CJTheme_IsDark())
	GuiControl, % guiName ": +c" C.accent, % ctrl
	GuiControl, % guiName ": MoveDraw", % ctrl
}
