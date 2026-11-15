/*
	CJWrite - correct or translate a text with the local LLM (OpenAI compatible chat API, e.g. SGLang)

	Triggers (Clipjump.ahk):  Action Mode + W / T  -> selected text; the result goes to the clipboard
	                          Ctrl+V + W / T       -> clip shown in paste mode; the result is pasted
	                                                  (without becoming a clip). Password clips are refused.
	  W = correct ("correct"), T = translate ("translate")

	Server: user environment variable LOCAL_LLM_URL, e.g. http://host:8004/v1/
	        (read from HKCU\Environment first, so "setx" works without restarting Clipjump).
	        Request: POST <url>/chat/completions. A URL that already ends in /chat/completions is used as is.

	Settings ([LocalLLM] in settings.ini, written with defaults by CJWrite_EnsureIni()):
	  model           = (empty: the first model the server lists under /models)
	  reasoningEffort = low    thinking level, sent as "reasoning_effort" (low / medium / high).
	                           none or off: thinking switched off (chat_template_kwargs enable_thinking=false)
	  prompt          = Korrigiere nur die Fehler im Text, formuliere ihn nicht um.          (W)
	  translatePrompt = Uebersetze den Text ins Englische. Ist der Text bereits auf Englisch,
	                    uebersetze ihn ins Deutsche.                                            (T)
	  timeoutSec      = 180

	A fixed output rule is appended to the prompt: the text is sent between <text> and </text> and the
	answer is taken from between these tags (keeps comments like "no errors found" out of the result).

	While the request runs a busy toast follows the mouse (like Hold Clip / Read aloud) and Esc cancels.
	Leading / trailing whitespace of the original text is kept around the result.

	NOTE: AHK variable names are case-insensitive. Never use pairs like y/Y, g/G, w/W in one function.
	NOTE: never name a local variable like a super-global (txt = TXT, the language object!).
*/

global CJW 	; state object (created on first use)

CJWrite_EnsureIni(){
	Ini_write("LocalLLM", "model", "")
	Ini_write("LocalLLM", "reasoningEffort", "low")
	Ini_write("LocalLLM", "prompt", CJWrite_DefaultPrompt("correct"))
	Ini_write("LocalLLM", "translatePrompt", CJWrite_DefaultPrompt("translate"))
	Ini_write("LocalLLM", "timeoutSec", 180)
}

CJWrite_DefaultPrompt(task){
	if (task = "translate")
		return Chr(220) "bersetze den Text ins Englische. Ist der Text bereits auf Englisch, " Chr(252) "bersetze ihn ins Deutsche."
	return "Korrigiere nur die Fehler im Text, formuliere ihn nicht um."
}

CJWrite_Config(task := "correct"){
	cfg := {}
	RegRead, u, HKCU\Environment, LOCAL_LLM_URL
	if (u = "")
		EnvGet, u, LOCAL_LLM_URL
	u := RTrim(Trim(u), "/")
	cfg.api := RegExReplace(u, "i)/chat/completions$")
	cfg.url := (u = "") ? "" : cfg.api "/chat/completions"
	cfg.model := Trim(Ini_read("LocalLLM", "model"))
	cfg.effort := Trim(Ini_read("LocalLLM", "reasoningEffort"))
	cfg.prompt := Trim(Ini_read("LocalLLM", task = "translate" ? "translatePrompt" : "prompt"))
	if (cfg.prompt = "")
		cfg.prompt := CJWrite_DefaultPrompt(task)
	t := Trim(Ini_read("LocalLLM", "timeoutSec"))
	if t is not integer
		t := 180
	cfg.timeout := t > 0 ? t : 180
	return cfg
}

CJWrite_Correct(text, mode := "selection"){
	return CJWrite_Run("correct", text, mode)
}

CJWrite_Translate(text, mode := "selection"){
	return CJWrite_Run("translate", text, mode)
}

; task: "correct" or "translate"; mode: "selection" (result replaces the selection when the target is
; editable and still focused, else it goes to the clipboard), "clip" (result pasted)
; or "return" (result returned, nothing else; "" when it failed, was cancelled or replaced by a newer call)
CJWrite_Run(task, text, mode := "selection"){
	global copyMessage, ini_IsMessage
	Critical, Off 		; called after endPastemode (Critical): Esc and the busy timer must be able to run
	if !IsObject(CJW)
		CJW := {gen: 0}
	CJWrite_BusyOff()
	myGen := ++CJW.gen
	CJW.cancel := 0
	isTr := (task = "translate")
	if (mode = "selection")
		target := CJWrite_Target() 	; where the selection is: checked again when the answer is there

	RegExMatch(text, "^\s*", lead) , RegExMatch(text, "\s*$", trail)
	core := Trim(text, " `t`r`n")
	if (core = "")
		return CJWrite_Msg(mode = "clip" ? TXT.TIP_llm_noclip : TXT.TIP_llm_notext)
	if CJPassword_IsPasswordText(core) 		; passwords never leave Clipjump (every caller passes here)
		return CJWrite_Msg(TXT.TIP_llm_password, "warn")
	cfg := CJWrite_Config(task)
	if (cfg.url = "")
		return CJWrite_Msg(TXT.TIP_llm_nourl, "warn", 4000)

	CJWrite_Busy(isTr ? TXT.TIP_llm_translating : TXT.TIP_llm_working)
	if (cfg.model = "") {
		cfg.model := CJWrite_DefaultModel(cfg.api)
		if (CJW.gen != myGen)
			return
		if (cfg.model = "")
			return CJWrite_End(myGen, TXT.TIP_llm_error " (/models)`n" cfg.api)
	}

	; ---- request ----
	; fixed output rule after the user's prompt: the text is framed with <text> tags and the answer is
	; taken from between them (without it the model comments on error-free texts or even replaces them)
	sys := cfg.prompt "`n`nDer Text steht zwischen <text> und </text>. Antworte ausschlie" Chr(223) "lich mit "
	if isTr
		sys .= "der " Chr(220) "bersetzung zwischen <text> und </text>, ohne Kommentar oder Erkl" Chr(228) "rung."
	else
		sys .= "dem korrigierten Text zwischen <text> und </text>, ohne Kommentar oder Erkl" Chr(228) "rung. "
			. "Ist der Text fehlerfrei, gib ihn unver" Chr(228) "ndert zur" Chr(252) "ck."
	body := "{""model"":""" CJSpeak_Json(cfg.model) """,""temperature"":0,""stream"":false"
		. ",""messages"":[{""role"":""system"",""content"":""" CJSpeak_Json(sys) """}"
		. ",{""role"":""user"",""content"":""" CJSpeak_Json("<text>`n" core "`n</text>") """}]"
	eff := cfg.effort 		; "if var in" needs a plain variable
	if eff in none,off,0
		body .= ",""chat_template_kwargs"":{""enable_thinking"":false}"
	else if (eff != "")
		body .= ",""reasoning_effort"":""" CJSpeak_Json(eff) """"
	body .= "}"
	try {
		req := ComObjCreate("WinHttp.WinHttpRequest.5.1")
		req.Open("POST", cfg.url, true)
		req.SetTimeouts(5000, 10000, 15000, cfg.timeout * 1000)
		req.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
		req.SetRequestHeader("Accept", "application/json")
		req.Send(CJSpeak_Utf8(body))
	} catch e
		return CJWrite_End(myGen, TXT.TIP_llm_error " " e.Message)
	started := A_TickCount
	loop {
		if (CJW.gen != myGen)
			return
		if CJW.cancel {
			try req.Abort()
			return CJWrite_End(myGen, TXT.TIP_cancelled, "info")
		}
		try done := req.WaitForResponse(0)
		catch e
			return CJWrite_End(myGen, TXT.TIP_llm_error " " e.Message)
		if done
			break
		if (A_TickCount - started > cfg.timeout * 1000 + 5000) {
			try req.Abort()
			return CJWrite_End(myGen, TXT.TIP_llm_error " Timeout")
		}
		sleep 50
	}
	if (CJW.gen != myGen)
		return
	status := req.Status
	resp := CJWrite_Body(req)
	if (status != 200)
		return CJWrite_End(myGen, TXT.TIP_llm_error " (HTTP " status ")`n" SubStr(CJWrite_JsonString(resp, "message"), 1, 200))
	out := CJWrite_JsonString(resp, "content")
	out := RegExReplace(out, "s)^\s*<think>.*?</think>")
	if RegExMatch(out, "s)<text>(.*?)</text>", m)
		out := m1
	out := Trim(out, " `t`r`n")
	if (out = "")
		return CJWrite_End(myGen, TXT.TIP_llm_error " (" TXT.TIP_llm_empty ")")
	CJWrite_End(myGen)
	same := !isTr && (out == core)
	out := lead out trail

	; ---- result ----
	if (mode = "return") 		; Clip Actions window: the caller shows / pastes it ("" = failed or cancelled)
		return out
	if (mode = "clip") {
		cjPasteTextNoClip(out)
		if same
			CJWrite_Msg(TXT.TIP_llm_nochange, "info", 1500)
		return
	}
	if (mode = "selection" && CJWrite_SameTarget(target)) { 	; replace the selection, no clip
		if same 						; nothing to replace
			return CJWrite_Msg(TXT.TIP_llm_nochange, "info", 1500)
		cjPasteTextNoClip(out)
		; check: if the original selection can still be copied, the paste did nothing (read-only
		; document or web page) - then the result goes to the clipboard below
		sleep 150
		if !(CopytoVar(0.4) == text)
			return CJWrite_Msg(isTr ? TXT.TIP_llm_trReplaced : TXT.TIP_llm_replaced, "check", 1500)
	}
	msg := isTr ? TXT.TIP_llm_translated : same ? TXT.TIP_llm_nochange "`n" TXT.TIP_llm_toclip : TXT.TIP_llm_done
	if ini_IsMessage {
		copyMessage := msg " {" CN.Name "}" 	; shown by the copy notification of the new clip
		SetTimer, copyMessage_restore, -2000
		try Clipboard := out
	} else {
		try Clipboard := out
		CJWrite_Msg(msg, "check", 1500)
	}
}
; the active window and its focused control, and whether the selection there may be replaced:
; edit := 0 when UI Automation says the element is read-only (read-only edit controls and web pages may
; show a caret too) or the window is a console / Explorer (Ctrl+V there would type into the command
; line or paste files), else 1. Apps such as Word report neither a value pattern nor a caret: there the
; replacement is tried and checked afterwards (CJWrite_Run).
CJWrite_Target(){
	static noPaste := "|ConsoleWindowClass|CASCADIA_HOSTING_WINDOW_CLASS|mintty|PuTTY|VirtualConsoleClass"
		. "|CabinetWClass|ExploreWClass|Progman|WorkerW|Shell_TrayWnd|"
	t := {win: WinExist("A"), focus: 0, caret: 0, edit: 0}
	if !t.win
		return t
	cb := A_PtrSize = 8 ? 72 : 48
	VarSetCapacity(gti, cb, 0) , NumPut(cb, gti, 0, "UInt")
	tid := DllCall("GetWindowThreadProcessId", "Ptr", t.win, "Ptr", 0, "UInt")
	if DllCall("GetGUIThreadInfo", "UInt", tid, "Ptr", &gti) {
		t.focus := NumGet(gti, A_PtrSize = 8 ? 16 : 12, "Ptr")
		t.caret := NumGet(gti, A_PtrSize = 8 ? 48 : 28, "Ptr")
	}
	WinGetClass, cls, % "ahk_id " t.win
	t.edit := !InStr(noPaste, "|" cls "|") && (CJWrite_UiaEditable() != 0)
	return t
}

; still the same window and control, and editable?
CJWrite_SameTarget(t){
	if !IsObject(t) || !t.edit || !t.win
		return 0
	now := CJWrite_Target()
	return now.win = t.win && (!t.focus || now.focus = t.focus)
}

; focused element by UI Automation: 1 = editable value, 0 = read-only, -1 = unknown (no value pattern)
CJWrite_UiaEditable(){
	static uia := 0
	if !uia
		try uia := ComObjCreate("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
	if !uia
		return -1
	el := 0 , res := -1
	if (DllCall(NumGet(NumGet(uia+0) + 8*A_PtrSize), "Ptr", uia, "Ptr*", el) != 0 || !el) 	; GetFocusedElement
		return -1
	VarSetCapacity(v, 24, 0)
	getProp := NumGet(NumGet(el+0) + 10*A_PtrSize) 			; GetCurrentPropertyValue
	if (DllCall(getProp, "Ptr", el, "Int", 30043, "Ptr", &v) = 0 	; IsValuePatternAvailable
		&& NumGet(v, 0, "UShort") = 11 && NumGet(v, 8, "Short")) {
		VarSetCapacity(v, 24, 0)
		if (DllCall(getProp, "Ptr", el, "Int", 30046, "Ptr", &v) = 0 && NumGet(v, 0, "UShort") = 11) 	; Value.IsReadOnly
			res := NumGet(v, 8, "Short") ? 0 : 1
	}
	ObjRelease(el)
	return res
}

; first model id listed by the server ("" if none)
CJWrite_DefaultModel(base){
	static cache := {}
	if cache.HasKey(base)
		return cache[base]
	try {
		req := ComObjCreate("WinHttp.WinHttpRequest.5.1")
		req.Open("GET", base "/models", false)
		req.SetTimeouts(3000, 5000, 5000, 10000)
		req.Send()
		if (req.Status = 200 && RegExMatch(CJWrite_Body(req), """id""\s*:\s*""((?:[^""\\]|\\.)*)""", m))
			return cache[base] := CJWrite_Unescape(m1)
	}
	return ""
}

; response body decoded as UTF-8 (ResponseText guesses the charset)
CJWrite_Body(req){
	try {
		st := ComObjCreate("ADODB.Stream")
		st.Type := 1 , st.Open()
		st.Write(req.ResponseBody)
		st.Position := 0 , st.Type := 2 , st.Charset := "utf-8"
		respText := st.ReadText()
		st.Close()
		return respText
	}
	try return req.ResponseText
	return ""
}

; value of the first JSON string "key": "..." (unescaped)
CJWrite_JsonString(json, key){
	if RegExMatch(json, """" key """\s*:\s*""((?:[^""\\]|\\.)*)""", m)
		return CJWrite_Unescape(m1)
	return ""
}

CJWrite_Unescape(s){
	s := StrReplace(s, "\\", Chr(1)) 	; protect escaped backslashes
	s := StrReplace(s, "\""", """") , s := StrReplace(s, "\/", "/")
	s := StrReplace(s, "\n", "`n") , s := StrReplace(s, "\r", "`r") , s := StrReplace(s, "\t", "`t")
	s := StrReplace(s, "\b", Chr(8)) , s := StrReplace(s, "\f", Chr(12))
	while RegExMatch(s, "\\u([0-9a-fA-F]{4})", m)
		s := StrReplace(s, m, Chr("0x" m1))
	return StrReplace(s, Chr(1), "\")
}

CJWrite_Busy(msg){
	CJW.busyText := msg
	if CJPanel_Enabled() {
		SetTimer, CopyToastOff, Off
		CJPanel_ShowToast(msg,,, "busy")
	} else
		btt(msg,,, 9)
	if !CJW.busyOn {
		CJW.busyOn := 1
		hkZ("Esc", "CJWrite_Cancel", 1)
		SetTimer, CJWrite_FollowTick, 30
	}
}

CJWrite_BusyOff(){
	if !IsObject(CJW) || !CJW.busyOn
		return
	CJW.busyOn := 0
	SetTimer, CJWrite_FollowTick, Off
	hkZ("Esc", "CJWrite_Cancel", 0)
	if CJPanel_Enabled()
		CJPanel_Hide("toast")
	else
		btt(,,, 9)
}

CJWrite_End(myGen, msg := "", icon := "warn"){
	if (CJW.gen != myGen)
		return
	CJWrite_BusyOff()
	if (msg != "")
		CJWrite_Msg(msg, icon, icon = "warn" ? 4000 : 1200)
}

CJWrite_Msg(msg, icon := "warn", time := 2500){
	autoTooltip(msg, time, 9, icon)
}

CJWrite_FollowTick:
	if !CJW.busyOn
		SetTimer, CJWrite_FollowTick, Off
	else if CJPanel_Enabled()
		CJPanel_Follow("toast")
	else
		btt(CJW.busyText,,, 9)
	return

CJWrite_Cancel:
	CJW.cancel := 1
	return
