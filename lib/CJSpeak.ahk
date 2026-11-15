/*
	CJSpeak - read text aloud with ElevenLabs text-to-speech

	Triggers (Clipjump.ahk):  Action Mode + R  -> selected text (CopytoVar)
	                          Ctrl+V + R       -> clip shown in paste mode

	Settings ([ElevenLabs] in settings.ini, written with defaults by CJSpeak_EnsureIni()):
	  voiceId  = ElevenLabs voice id (required)
	  modelId  = eleven_multilingual_v2
	  maxChars = 5000                     (longer texts are cut: every character costs credits)
	  mp3Dir   = c:\my\mp3                (the generated MP3 files are kept there)
	API key: user environment variable ELEVENLABS_API_KEY (never stored in settings.ini).
	         Read from HKCU\Environment first, so "setx" works without restarting Clipjump.

	While the request runs and while the audio plays, a busy toast follows the mouse (like Hold Clip)
	and Esc cancels. Esc is only taken while that is the case.

	A new call while one is running stops the running one: each call has a generation number, and an
	older call that resumes after a newer one ends without touching anything.

	NOTE: AHK variable names are case-insensitive. Never use pairs like y/Y, g/G, w/W in one function.
*/

global CJS	; state object (created on first use: this file is included after the auto-execute section)

CJSpeak_EnsureIni(){
	Ini_write("ElevenLabs", "voiceId", "")
	Ini_write("ElevenLabs", "modelId", "eleven_multilingual_v2")
	Ini_write("ElevenLabs", "maxChars", 5000)
	Ini_write("ElevenLabs", "mp3Dir", "c:\my\mp3")
}

CJSpeak_Config(){
	cfg := {}
	RegRead, k, HKCU\Environment, ELEVENLABS_API_KEY
	if (k = "")
		EnvGet, k, ELEVENLABS_API_KEY
	cfg.key := Trim(k)
	cfg.voice := Trim(Ini_read("ElevenLabs", "voiceId"))
	cfg.model := Trim(Ini_read("ElevenLabs", "modelId"))
	if (cfg.model = "")
		cfg.model := "eleven_multilingual_v2"
	mx := Trim(Ini_read("ElevenLabs", "maxChars"))
	if mx is not integer
		mx := 5000
	cfg.max := mx > 0 ? mx : 5000
	cfg.dir := RTrim(Trim(Ini_read("ElevenLabs", "mp3Dir")), "\")
	if (cfg.dir = "")
		cfg.dir := "c:\my\mp3"
	return cfg
}

; source: "selection" or "clip" (only changes the message for an empty text)
CJSpeak_Text(text, source := "selection"){
	Critical, Off 		; called after endPastemode (Critical): Esc and the follow timer must be able to run
	if !IsObject(CJS)
		CJS := {gen: 0}
	CJSpeak_StopAll() 			; a running request/playback ends here
	myGen := ++CJS.gen
	CJS.cancel := 0

	text := Trim(text, " `t`r`n")
	if (text = "")
		return CJSpeak_Msg(source = "clip" ? TXT.TIP_tts_noclip : TXT.TIP_tts_notext, "warn")
	if CJPassword_IsPasswordText(text) 		; passwords never leave Clipjump (every caller passes here)
		return CJSpeak_Msg(TXT.TIP_tts_password, "warn")
	cfg := CJSpeak_Config()
	if (cfg.key = "")
		return CJSpeak_Msg(TXT.TIP_tts_nokey, "warn", 4000)
	if (cfg.voice = "")
		return CJSpeak_Msg(TXT.TIP_tts_novoice, "warn", 4000)
	note := ""
	if (StrLen(text) > cfg.max)
		text := SubStr(text, 1, cfg.max) , note := "`n" StrReplace(TXT.TIP_tts_truncated, "%n%", cfg.max)

	; ---- request ----
	CJSpeak_Busy(TXT.TIP_tts_loading note)
	body := "{""text"":""" CJSpeak_Json(text) """,""model_id"":""" CJSpeak_Json(cfg.model) """}"
	url := "https://api.elevenlabs.io/v1/text-to-speech/" cfg.voice "?output_format=mp3_44100_128"
	try {
		req := ComObjCreate("WinHttp.WinHttpRequest.5.1")
		req.Open("POST", url, true)
		req.SetTimeouts(10000, 10000, 15000, 60000)
		req.SetRequestHeader("xi-api-key", cfg.key)
		req.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
		req.SetRequestHeader("Accept", "audio/mpeg")
		req.Send(CJSpeak_Utf8(body))
	} catch e
		return CJSpeak_End(myGen, TXT.TIP_tts_error " " e.Message)
	started := A_TickCount
	loop {
		if (CJS.gen != myGen)
			return
		if CJS.cancel {
			try req.Abort()
			return CJSpeak_End(myGen, TXT.TIP_cancelled, "info")
		}
		try done := req.WaitForResponse(0)
		catch e
			return CJSpeak_End(myGen, TXT.TIP_tts_error " " e.Message)
		if done
			break
		if (A_TickCount - started > 65000) {
			try req.Abort()
			return CJSpeak_End(myGen, TXT.TIP_tts_error " Timeout")
		}
		sleep 50
	}
	if (CJS.gen != myGen)
		return
	status := req.Status
	if (status != 200)
		return CJSpeak_End(myGen, TXT.TIP_tts_error " (HTTP " status ")`n" CJSpeak_ApiMessage(req))

	; ---- save the MP3 (kept in mp3Dir) ----
	if !InStr(FileExist(cfg.dir), "D")
		FileCreateDir, % cfg.dir
	if !InStr(FileExist(cfg.dir), "D")
		return CJSpeak_End(myGen, TXT.TIP_tts_nodir "`n" cfg.dir)
	path := CJSpeak_FileName(cfg.dir, text)
	try {
		st := ComObjCreate("ADODB.Stream")
		st.Type := 1 , st.Open()
		st.Write(req.ResponseBody)
		st.SaveToFile(path, 2)
		st.Close()
	} catch e
		return CJSpeak_End(myGen, TXT.TIP_tts_nodir "`n" path)
	req := ""

	; ---- play (MCI: can be stopped, and we see when it ends) ----
	CJSpeak_Mci("close cjtts")
	if CJSpeak_Mci("open """ path """ type mpegvideo alias cjtts").err
		return CJSpeak_End(myGen, TXT.TIP_tts_error " (MCI open)`n" path)
	CJSpeak_Mci("play cjtts")
	CJS.playing := 1
	CJSpeak_Busy(TXT.TIP_tts_playing)
	loop {
		sleep 100
		if (CJS.gen != myGen)
			return 		; a newer call closed the device already
		if CJS.cancel
			break
		mode := CJSpeak_Mci("status cjtts mode").out
		if (mode != "playing" && mode != "seeking")
			break
	}
	CJSpeak_Mci("close cjtts") , CJS.playing := 0
	CJSpeak_End(myGen)
}

; stops whatever runs now (playback, busy toast, Esc); the running call notices via CJS.gen
CJSpeak_StopAll(){
	if !IsObject(CJS)
		return
	if CJS.playing
		CJSpeak_Mci("close cjtts") , CJS.playing := 0
	CJSpeak_BusyOff()
}

CJSpeak_Busy(msg){
	CJS.busyText := msg
	if CJPanel_Enabled() {
		SetTimer, CopyToastOff, Off
		CJPanel_ShowToast(msg,,, "busy")
	} else
		btt(msg,,, 9)
	if !CJS.busyOn {
		CJS.busyOn := 1
		hkZ("Esc", "CJSpeak_Cancel", 1)
		SetTimer, CJSpeak_FollowTick, 30
	}
}

CJSpeak_BusyOff(){
	if !CJS.busyOn
		return
	CJS.busyOn := 0
	SetTimer, CJSpeak_FollowTick, Off
	hkZ("Esc", "CJSpeak_Cancel", 0)
	if CJPanel_Enabled()
		CJPanel_Hide("toast")
	else
		btt(,,, 9)
}

; ends a call: busy indicator off, optional message (warn by default)
CJSpeak_End(myGen, msg := "", icon := "warn"){
	if (CJS.gen != myGen)
		return
	CJSpeak_BusyOff()
	if (msg != "")
		CJSpeak_Msg(msg, icon, icon = "warn" ? 4000 : 1200)
}

CJSpeak_Msg(msg, icon := "warn", time := 2500){
	autoTooltip(msg, time, 9, icon)
}

CJSpeak_Mci(cmd){
	VarSetCapacity(buf, 512 * 2, 0)
	err := DllCall("winmm\mciSendStringW", "Str", cmd, "Ptr", &buf, "UInt", 512, "Ptr", 0, "UInt")
	return {err: err, out: StrGet(&buf, "UTF-16")}
}

; JSON string content: backslash, quote and control characters escaped
CJSpeak_Json(s){
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, """", "\""")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`t", "\t")
	loop 31
		if InStr(s, Chr(A_Index))
			s := StrReplace(s, Chr(A_Index), Format("\u{:04X}", A_Index))
	return s
}

; text -> UTF-8 bytes (SAFEARRAY, no BOM) for WinHttp's Send()
CJSpeak_Utf8(str){
	st := ComObjCreate("ADODB.Stream")
	st.Type := 2 , st.Charset := "utf-8" , st.Open()
	st.WriteText(str)
	st.Position := 0 , st.Type := 1 , st.Position := 3 	; skip the BOM ADODB writes
	bytes := st.Read()
	st.Close()
	return bytes
}

; "detail.message" (or "detail") of an ElevenLabs error answer
CJSpeak_ApiMessage(req){
	try respText := req.ResponseText
	if RegExMatch(respText, """message""\s*:\s*""((?:[^""\\]|\\.)*)""", m)
		return StrReplace(m1, "\""", """")
	if RegExMatch(respText, """detail""\s*:\s*""((?:[^""\\]|\\.)*)""", m)
		return StrReplace(m1, "\""", """")
	return SubStr(respText, 1, 200)
}

; <dir>\yyyyMMdd-HHmmss_First-words.mp3 (unique)
CJSpeak_FileName(dir, text){
	FormatTime, ts,, yyyyMMdd-HHmmss
	words := RegExReplace(SubStr(text, 1, 200), "[\\/:*?""<>|\x00-\x1F]+", " ")
	words := Trim(RegExReplace(words, "\s+", "-"), "-")
	words := RTrim(SubStr(words, 1, 40), "-. ")
	base := dir "\" ts (words != "" ? "_" words : "")
	path := base ".mp3"
	while FileExist(path)
		path := base "-" (A_Index + 1) ".mp3"
	return path
}

CJSpeak_FollowTick:
	if !CJS.busyOn
		SetTimer, CJSpeak_FollowTick, Off
	else if CJPanel_Enabled()
		CJPanel_Follow("toast")
	else
		btt(CJS.busyText,,, 9) 		; classic tooltip: redrawn at the mouse
	return

CJSpeak_Cancel:
	CJS.cancel := 1
	return
