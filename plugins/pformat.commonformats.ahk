;@Plugin-Name Clip Actions
;@Plugin-Description Clip Actions: translate, correct (local LLM) or read aloud a clip, or paste it with one of many predefined formats. Can be easily extended to include more formats. 
;@Plugin-Description For that edit the pformat.commonformats.lib/user.ahk file. This file if needed is created when you run this plugin for the first time. 
;@Plugin-Description Only works for Text ([Text] or [File/Folder]) type data.
;@Plugin-Author Avi
;@Plugin-Tags pformat
;@Plugin-version 0.61
;@Plugin-Previewable 0
; Modified for Clipjump-Ultra by Erhan Tuna, 2026 - see NOTICE.txt (Apache License 2.0)

;@Plugin-Param1 The Input Text

;------------------------------------------------------------- Paste Formats ------------------------------------

; ###### ADD USER paste formats in user.ahk file #####
#Include *i %A_ScriptDir%\plugins\pformat.commonformats.lib\user.ahk
; ####################################################


plugin_pformat_commonformats_None(zin){
	STORE["commonformats_None"] := "This returns the original clip rejecting any change made to the clip."
	return zin , STORE.ClipboardChanged := 0
}

plugin_pformat_commonformats_HTMLList(zin){
	return RegExReplace( Trim(zin, "`r`n "), "m`a)^", "<li>") , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_BBCodeList(zin){
	return RegExReplace( Trim(zin, "`r`n "), "m`a)^", "[*]") , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_TrimFormatting(zin){
	return RTrim(zin, "`r`n") , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_NumberedList(zin){
	zin := Trim(zin, "`r`n ")
	loop, parse, zin, `n, `r
		zout .= A_index ". " A_LoopField "`r`n"
	return zout , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_lowercase(zin){
	StringLower, zout, zin
	return zout , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_TrimWhiteSpace(zin){
	STORE["commonformats_TrimWhiteSpace"] := "Trims white space from the beginning and end of string"
	return Trim(zin, "`r`n `t") , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_DeHTML(zin){
	STORE["commonformats_DeHTML"] := "Deactivates HTML code. All ("" & < >) are translated to (&quot; &amp; &lt; &gt;) and linefeed \n to <br>."
	Transform, o, HTML, % zin
	return plugin_pformat_commonformats_TrimWhiteSpace(o)
}

plugin_pformat_commonformats_UPPERCASE(zin){
	StringUpper, zout, zin
	return zout , STORE.ClipboardChanged := 1
}

#Include *i %A_ScriptDir%\plugins\pformat.commonformats.lib\unhtml.ahk
plugin_pformat_commonformats_UnHTML(zin){
	STORE["commonformats_unhtml"] := "Converts HTML code to Plain Text. Removes tags from HTML code and converts unicode sequences to characters."
	StringReplace, zin, zin, % "<br>", % "`n", All
	return Trim(unhtml(zin), "`n`r`t ") , STORE.ClipboardChanged := 1
}

plugin_pformat_commonformats_RegexReplace(zin, zps){
	STORE["commonformats_RegexReplace"] := "Write Search Needle in first line and replacement string in second line in Input Field. The Replace is based on Autohotkey's"
	 . " RegexReplace(). Learn more at http://www.autohotkey.com/docs/commands/RegExReplace.htm"

	loop, parse, zps, `n, `r
		zps%A_index% := A_LoopField
	try 
		zout := RegExReplace(zin, zps1, zps2)
	catch 
		zout := zin
	return zout , STORE.ClipboardChanged := 1
}


;--------------------------------- The Plugin File Starts , end of Paste Formats ---------------------------------
;-----------------------------------------------------------------------------------------------------------------


plugin_pformat_commonformats(zin){
	global realActive 		; clip shown in paste mode (password check)
	static zchosenformat, zedit, zinputfield, zinfo, zhEdit, zhInfo, zhInput, zhList
	zDone := zOut := ""

	; layout: list | clip text, then Info, Input Field and the buttons (bottom right).
	; The list is a ListView (not a ListBox): its selection is drawn properly in dark mode.
	; A change of the selected row (mouse or keyboard) is picked up by the wait loop below (no AltSubmit:
	; its flood of item notifications interrupts the format threads). Mouse clicks / double clicks on a row come
	; as WM_NOTIFY (NM_CLICK / NM_DBLCLK, see plugin_pformat_commonformats_notify) and are handled in the loop:
	; without AltSubmit the ListView g-label gets no event for a simple click.
	; zchosenformat (static: remembered for the next call) is set from the list in the zchosenformat label.
	;
	; Clip actions (top of the list): Translate / Correct (local LLM, lib/CJWrite.ahk) and Read aloud
	; (ElevenLabs, lib/CJSpeak.ahk). Selecting such a row does nothing yet; only a mouse CLICK on it sends
	; the request (busy toast follows the mouse, Esc cancels). OK / double click pastes the result
	; (computed first if needed). Results are kept per action until the text changes (Apply).
	zActs := plugin_pformat_commonformats_actions() , zActByName := {} , zCache := {}
	for zk, zv in zActs
		zActByName[zv.name] := zv
	zIsPw := (CJPassword_IsPwClip(CN.NG, realActive) && (zin == CDS[CN.NG][realActive]))
		|| CJPassword_IsPasswordText(zin) 	; never sent to the LLM / ElevenLabs
	STORE.cf_text := zin

	zLW := 160, zEW := 520, zFW := zLW + 10 + zEW, zBW := 90
	Gui, commonformat:New
	Gui, +AlwaysOnTop +ToolWindow -MaximizeBox
	Gui, Margin, 12, 12
	CJTheme_GuiFont("commonformat")		; system (menu) font in the modern design (no-op in classic style)

	Gui, Add, ListView, % "xm ym r16 w" zLW " -Hdr -Multi +LV0x10000 HwndzhList", Format
	for zk, zv in zActs
		LV_Add("", zv.name)
	zlist := plugin_pformat_commonformats_listfunc(A_ScriptDir "\plugins\pformat.commonformats.ahk")
	. ( (ztemp := plugin_pformat_commonformats_listfunc(ztF := A_ScriptDir "\plugins\pformat.commonformats.lib\user.ahk")) ? "|" ztemp : "" )
	loop, parse, zlist, |
		LV_Add("", A_LoopField)
	SysGet, zSBW, 2		; SM_CXVSCROLL: room for a scroll bar (more formats than visible rows)
	LV_ModifyCol(1, zLW - 4 - (LV_GetCount() > 16 ? zSBW : 0))

	if CJTheme_Enabled()		; modern design: clip text in the same font as the paste mode panel
		Gui, Font, s10, % (ini_pasteModeFont != "" ? ini_pasteModeFont : "Segoe UI")
	Gui, Add, Edit, % "x+10 yp w" zEW " hp vzedit HwndzhEdit +multi", % zin
	Gui, Font
	CJTheme_GuiFont("commonformat")

	Gui, Add, Text, xm y+12, Info
	Gui, Add, Text, % "xm y+4 w" zFW " h36 vzinfo HwndzhInfo",

	Gui, Add, Text, xm y+10, Input Field
	Gui, Font, s10, Lucida Console
	Gui, Font, s10, Consolas
	Gui, Add, Edit, % "xm y+4 w" zFW " h40 -VScroll gzinputfield vzinputfield HwndzhInput",
	Gui, Font
	CJTheme_GuiFont("commonformat")

	Gui, Add, Button, % "x" 12 + zFW - 2*zBW - 8 " y+14 w" zBW " +Default", OK
	Gui, Add, Button, % "x+8 yp w" zBW " gplugin_pformat_commonformats_apply", % TXT.SET_apply
	CJTheme_Apply("commonformat")		; Windows 11 look, light/dark (no-op in classic style)
	Gui, commonformat:Show,, % "Clip Actions"

	if !FileExist(ztF)
	{
		FileCreateDir, % Substr(ztF, 1, Instr(ztF, "\", 0, 0)-1)
		FileAppend, % "; Add User paste formats here`n; Prefix - plugin_pformat_commonformats_", % ztF
	}

	zsel := zchosenformat="" ? "None" : zchosenformat 	; choose the previous active format
	loop % LV_GetCount()
	{
		LV_GetText(ztemp, A_Index)
		if (ztemp = zsel) {
			LV_Modify(A_Index, "Select Focus Vis")
			break
		}
	}
	gosub zchosenformat
	zlastrow := LV_GetNext()
	zDone := 0
	STORE.cf_lv := zhList , STORE.cf_click := STORE.cf_dbl := 0
	OnMessage(0x4E, "plugin_pformat_commonformats_notify") 	; WM_NOTIFY: clicks on the list
	Critical, Off 	; the buttons are new threads
	while !zDone
	{
		sleep 50
		Gui, commonformat:Default
		if ((zrow := LV_GetNext()) && zrow != zlastrow)
		{
			zlastrow := zrow
			gosub zchosenformat
		}
		if STORE.cf_click 		; mouse click on a row: a clip action sends its request now
		{
			STORE.cf_click := 0
			if IsObject(zA := zActByName[zchosenformat])
				plugin_pformat_commonformats_doAction(zA, zin, zIsPw, zhEdit, zhInfo, zCache)
		}
		if (STORE.cf_dbl && !zDone) 	; double click = OK
		{
			STORE.cf_dbl := 0
			gosub commonformatbuttonOK
		}
	}
	OnMessage(0x4E, "plugin_pformat_commonformats_notify", 0)
	STORE.cf_lv := ""
	gosub plugin_pformat_commonformats_end
	return zOut

commonformatbuttonOK:
;plugin_pformat_commonformats_dopaste:
	Gui, commonformat:Submit, nohide
	if IsObject(zA := zActByName[zchosenformat])
	{
		if (zA.key = "read") 		; read aloud does not change the text
			zOut := zin , STORE.ClipboardChanged := 0
		else if zCache.HasKey(zA.key)
			zOut := zedit , STORE.ClipboardChanged := 1 	; the result as shown (may have been edited)
		else {
			zres := plugin_pformat_commonformats_doAction(zA, zin, zIsPw, zhEdit, zhInfo, zCache)
			if (zres = "")
				return 		; failed or cancelled: the window stays open
			zOut := zres , STORE.ClipboardChanged := 1
		}
		zDone := 1
		return
	}
	STORE.ClipboardChanged := 1 , zOut := zedit
	If (zchosenformat="None") or (zchosenformat="")
		zOut := zin, STORE.ClipboardChanged := 0
	zDone := 1
	return

commonformatGuiEscape:
commonformatGuiClose:
	zDone := 1
	STORE.ClipboardChanged := 1
	zOut := ""				; cancel paste if user escapes or closes the window
	return

plugin_pformat_commonformats_apply:
	Gui, commonformat:Submit, nohide
	zin := zEdit
	zCache := {} , STORE.cf_text := zin 	; new text: results of the clip actions are outdated
	return

plugin_pformat_commonformats_end:
	Gui, commonformat:Destroy 		; The original clip will be pasted if you close the gui
	WinWaitClose, Clip Actions
	return

zinputfield:
	Gui, commonformat:Submit, nohide
	if IsObject(zActByName[zchosenformat])
		return
	zoutput := ( zFobj.MaxParams > 1 ) ? zFobj.(zin, zinputfield) : zFobj.(zin)
	STORE.ClipboardChanged := 0 		; remove any clipboard change
	GuiControl, commonformat:, %zhEdit%, % zoutput
	GuiControl, commonformat:, %zhInfo%, % STORE["commonformats_" zchosenformat]
	return

zchosenformat:
	Gui, commonformat:Default
	if (zrow := LV_GetNext())
		LV_GetText(zchosenformat, zrow)
	GuiControl, commonformat:, %zhInput%, % ""
	Gui, commonformat:Submit, nohide
	if zchosenformat=
		zchosenformat := "None"
	STORE.cf_chosen := zchosenformat
	if IsObject(zA := zActByName[zchosenformat]) 	; clip action: show the result if there is one, else the text
	{
		GuiControl, commonformat:Disable, %zhInput%
		GuiControl, commonformat:, %zhEdit%, % zCache.HasKey(zA.key) ? zCache[zA.key] : zin
		GuiControl, commonformat:, %zhInfo%, % zA.info
		return
	}
	zFobj := Func("plugin_pformat_commonformats_" zchosenformat)
	if ( zFobj.MaxParams < 2 )
		GuiControl, commonformat:Disable, %zhInput%
	else {
		GuiControl, commonformat:Enable, %zhInput%
		GuiControl, commonformat:Focus, %zhInput%
	}
	gosub zinputfield
	return

}

; WM_NOTIFY of the window: a click (NM_CLICK) or double click (NM_DBLCLK) on a row of the list only sets a flag
; for the wait loop (keep this short: it runs for every notification of the window)
plugin_pformat_commonformats_notify(wParam, lParam){
	if (!STORE.cf_lv || NumGet(lParam+0, 0, "Ptr") != STORE.cf_lv)
		return
	code := NumGet(lParam+0, 2*A_PtrSize, "Int")
	if (code != -2 && code != -3)
		return
	if (NumGet(lParam+0, (A_PtrSize = 8) ? 24 : 12, "Int") < 0) 	; NMITEMACTIVATE.iItem: -1 = not on a row
		return
	if (code = -2)
		STORE.cf_click := 1
	else
		STORE.cf_dbl := 1
}

; clip actions at the top of the list: {key, name, info, busy}
plugin_pformat_commonformats_actions(){
	return [{key: "translate", name: TXT.TIP_ca_translate, info: TXT.TIP_ca_llminfo, busy: TXT.TIP_llm_translating}
		, {key: "correct", name: TXT.TIP_ca_correct, info: TXT.TIP_ca_llminfo, busy: TXT.TIP_llm_working}
		, {key: "read", name: TXT.TIP_ca_read, info: TXT.TIP_ca_readinfo, busy: TXT.TIP_tts_loading}]
}

; runs a clip action (own function: its variables stay its own while other clicks interrupt it).
; Returns the LLM result ("" for read aloud, failure or cancel) and shows it if the action is still selected.
plugin_pformat_commonformats_doAction(act, text, isPw, hEdit, hInfo, cache){
	if isPw { 		; passwords never leave Clipjump: no LLM, no ElevenLabs
		autoTooltip(act.key = "read" ? TXT.TIP_tts_password : TXT.TIP_llm_password, 2500, 2, "warn")
		return ""
	}
	if (act.key = "read") {
		CJSpeak_Text(text, "clip") 		; busy toast + Esc of CJSpeak (checks passwords again)
		return ""
	}
	if cache.HasKey(act.key) {
		GuiControl, commonformat:, %hEdit%, % cache[act.key]
		return cache[act.key]
	}
	GuiControl, commonformat:, %hInfo%, % act.busy
	res := CJWrite_Run(act.key, text, "return") 	; busy toast follows the mouse, Esc cancels
	if (res != "")
		cache[act.key] := res
	if !WinExist("ahk_id " hEdit) 		; window closed meanwhile
		return res
	if (STORE.cf_chosen = act.name && STORE.cf_text == text) {
		GuiControl, commonformat:, %hInfo%, % act.info
		if (res != "")
			GuiControl, commonformat:, %hEdit%, % res
	}
	return res
}
;---------------------------------- Functions used by this plugin -------------------

plugin_pformat_commonformats_listfunc(file){
	fileread, z, % file
	StringReplace, z, z, `r, , All			; important
	z := RegExReplace(z, "mU)""[^`n]*""", "") ; strings
	z := RegExReplace(z, "iU)/\*.*\*/", "") ; block comments
	z := RegExReplace(z, "m);[^`n]*", "")  ; single line comments
	p:=1 , z := "`n" z
	while q:=RegExMatch(z, "iU)`n[^ `t`n,;``\(\):=\?]+\([^`n]*\)[ `t`n]*{", o, p)
	{
		if IsFunc( zfk := Substr( RegExReplace(o, "\(.*", ""), 2) )
			If zfk not in plugin_pformat_commonformats_listfunc,plugin_pformat_commonformats,plugin_pformat_commonformats_actions,plugin_pformat_commonformats_doAction,plugin_pformat_commonformats_notify
				lst .= "`n" RegExReplace(zfk, "^(plugin_pformat_commonformats_)", "", "", 1)
		p := q+Strlen(o)-1
	}
	Sort, lst
	return Trim( RegExReplace(lst, "`n", "|"),"|" )
}

