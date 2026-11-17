/*
	CJSpeak - read text aloud with ElevenLabs text-to-speech

	Copyright 2026 Erhan Tuna - part of Clipjump-Ultra (https://github.com/magomic/Clipjump-Ultra)
	Licensed under the Apache License, Version 2.0 (see LICENSE and NOTICE.md)

	Triggers (Clipjump.ahk):  Action Mode + R  -> selected text (CopytoVar)
	                          Ctrl+V + R       -> clip shown in paste mode
	                          Clip Actions     -> "Read aloud" entry

	Settings ([ElevenLabs] in settings.ini, written with defaults by CJSpeak_EnsureIni(); Settings window):
	  voiceId     = ElevenLabs voice id (required)
	  modelId     = eleven_multilingual_v2
	  maxChars    = 5000        longer texts are cut: every character costs credits
	  mp3Dir      = c:\my\mp3   folder of the MP3 files and of the log
	  mp3Save     = 1           0: the MP3 is only played (temp file, deleted afterwards)
	  mp3KeepDays = 30          saved MP3 files older than this are deleted (0 = keep them)
	  mp3Cache    = 1           the same text (same voice + model) again: play the saved MP3, no new request
	API key: user environment variable ELEVENLABS_API_KEY (never stored in settings.ini).
	         Read from HKCU\Environment first, so "setx" works without restarting Clipjump.

	File names: <yyyyMMdd-HHmmss>-ElevenLabs.mp3 (no text in the name).
	Log: <mp3Dir>\ElevenLabs-Log.csv (UTF-8, ";"), one row per read-aloud:
	  Zeitpunkt;Datei;Zeichen;Quelle;Stimme;Modell;Ergebnis;Hash
	  Zeichen = characters sent (= credits used; 0 for a cache hit), Ergebnis = OK / Cache / error text,
	  Hash = SHA-256 of voice|model|text (finds the MP3 for the cache; the text itself is not stored).
	Credits: CJSpeak_Quota() asks ElevenLabs (/v1/user/subscription) - button in the Settings window.

	While the request runs and while the audio plays, a busy toast follows the mouse (like Hold Clip)
	and Esc cancels. Esc is only taken while that is the case.

	A new call while one is running stops the running one: each call has a generation number, and an
	older call that resumes after a newer one ends without touching anything.

	NOTE: AHK variable names are case-insensitive. Never use pairs like y/Y, g/G, w/W in one function.
	NOTE: never name a local variable like a super-global (txt = TXT, the language object!).
*/

global CJS	; state object (created on first use: this file is included after the auto-execute section)

CJSpeak_EnsureIni(){
	Ini_write("ElevenLabs", "voiceId", "")
	Ini_write("ElevenLabs", "modelId", "eleven_multilingual_v2")
	Ini_write("ElevenLabs", "maxChars", 5000)
	Ini_write("ElevenLabs", "mp3Dir", "c:\my\mp3")
	Ini_write("ElevenLabs", "mp3Save", 1)
	Ini_write("ElevenLabs", "mp3KeepDays", 30)
	Ini_write("ElevenLabs", "mp3Cache", 1)
	SetTimer, CJSpeak_CleanupTick, -60000 	; old MP3 files: once a minute after the start (then with every read-aloud)
}

CJSpeak_Config(){
	cfg := {}
	cfg.key := CJSpeak_ApiKey()
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
	cfg.save := Trim(Ini_read("ElevenLabs", "mp3Save")) = "0" ? 0 : 1
	kd := Trim(Ini_read("ElevenLabs", "mp3KeepDays"))
	if kd is not integer
		kd := 30
	cfg.keep := kd > 0 ? kd : 0
	cfg.cache := cfg.save && (Trim(Ini_read("ElevenLabs", "mp3Cache")) != "0")
	return cfg
}

CJSpeak_ApiKey(){
	RegRead, k, HKCU\Environment, ELEVENLABS_API_KEY
	if (k = "")
		EnvGet, k, ELEVENLABS_API_KEY
	return Trim(k)
}

; source: "selection" or "clip" (only changes the message for an empty text)
CJSpeak_Text(text, source := "selection"){
	Critical, Off 		; called after endPastemode (Critical): Esc and the follow timer must be able to run
	if !IsObject(CJS)
		CJS := {gen: 0}
	CJSpeak_StopAll() 			; a running request/playback ends here
	FileDelete, %A_Temp%\cj_tts_*.mp3 	; temp files of earlier calls (mp3Save = 0)
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
	hash := CJSpeak_Sha256(cfg.voice "|" cfg.model "|" text)
	CJSpeak_Cleanup(cfg)

	; ---- cache: the same text was read before and its MP3 still exists ----
	if (cfg.cache && (path := CJSpeak_CacheLookup(cfg.dir, hash)) != "") {
		CJSpeak_Log(cfg, path, 0, source, "Cache", hash)
		return CJSpeak_Play(myGen, path, 0)
	}

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
			CJSpeak_Log(cfg, "", 0, source, "Abgebrochen", hash)
			return CJSpeak_End(myGen, TXT.TIP_cancelled, "info")
		}
		try done := req.WaitForResponse(0)
		catch e
			return CJSpeak_End(myGen, TXT.TIP_tts_error " " e.Message)
		if done
			break
		if (A_TickCount - started > 65000) {
			try req.Abort()
			CJSpeak_Log(cfg, "", 0, source, "Timeout", hash)
			return CJSpeak_End(myGen, TXT.TIP_tts_error " Timeout")
		}
		sleep 50
	}
	if (CJS.gen != myGen)
		return
	status := req.Status
	if (status != 200) {
		CJSpeak_Log(cfg, "", 0, source, "HTTP " status, hash)
		return CJSpeak_End(myGen, TXT.TIP_tts_error " (HTTP " status ")`n" CJSpeak_ApiMessage(req))
	}

	; ---- save the MP3: mp3Dir (mp3Save = 1) or a temp file that is deleted after playing ----
	if (cfg.save) {
		if !InStr(FileExist(cfg.dir), "D")
			FileCreateDir, % cfg.dir
		if !InStr(FileExist(cfg.dir), "D")
			return CJSpeak_End(myGen, TXT.TIP_tts_nodir "`n" cfg.dir)
		path := CJSpeak_FileName(cfg.dir)
	} else
		path := A_Temp "\cj_tts_" A_TickCount ".mp3"
	try {
		st := ComObjCreate("ADODB.Stream")
		st.Type := 1 , st.Open()
		st.Write(req.ResponseBody)
		st.SaveToFile(path, 2)
		st.Close()
	} catch e
		return CJSpeak_End(myGen, TXT.TIP_tts_nodir "`n" path)
	req := ""
	CJSpeak_Log(cfg, cfg.save ? path : "", StrLen(text), source, "OK", hash)
	return CJSpeak_Play(myGen, path, !cfg.save)
}

; plays an MP3 with MCI (can be stopped, and we see when it ends); temp = delete the file afterwards
CJSpeak_Play(myGen, path, temp){
	CJSpeak_Mci("close cjtts")
	if CJSpeak_Mci("open """ path """ type mpegvideo alias cjtts").err
		return CJSpeak_End(myGen, TXT.TIP_tts_error " (MCI open)`n" path)
	CJSpeak_Mci("play cjtts")
	CJS.playing := 1
	CJSpeak_Busy(TXT.TIP_tts_playing)
	loop {
		sleep 100
		if (CJS.gen != myGen)
			return 		; a newer call closed the device already (it also deletes old temp files)
		if CJS.cancel
			break
		mode := CJSpeak_Mci("status cjtts mode").out
		if (mode != "playing" && mode != "seeking")
			break
	}
	CJSpeak_Mci("close cjtts") , CJS.playing := 0
	if temp
		FileDelete, %path%
	CJSpeak_End(myGen)
}

; ---------------------------------------------------------------- log, cache, clean-up, credits
CJSpeak_LogPath(dir){
	return dir "\ElevenLabs-Log.csv"
}

; one row per read-aloud (the text itself is never written; see the header comment)
CJSpeak_Log(cfg, path, chars, source, result, hash){
	if !InStr(FileExist(cfg.dir), "D")
		FileCreateDir, % cfg.dir
	f := CJSpeak_LogPath(cfg.dir)
	head := FileExist(f) ? "" : "Zeitpunkt;Datei;Zeichen;Quelle;Stimme;Modell;Ergebnis;Hash`r`n"
	FormatTime, ts,, yyyy-MM-dd HH:mm:ss
	SplitPath, path, name
	row := ts ";" name ";" chars ";" source ";" cfg.voice ";" cfg.model ";" StrReplace(result, ";", ",") ";" hash "`r`n"
	FileAppend, % head row, %f%, UTF-8
}

; newest saved MP3 of this hash that still exists ("" = none)
CJSpeak_CacheLookup(dir, hash){
	FileRead, log, % CJSpeak_LogPath(dir)
	if ErrorLevel
		return ""
	found := ""
	loop, parse, log, `n, `r
	{
		col := StrSplit(A_LoopField, ";")
		if (col[8] == hash && col[2] != "" && FileExist(dir "\" col[2]))
			found := dir "\" col[2] 	; keep going: the newest row wins
	}
	return found
}

; deletes saved MP3 files (only Clipjump's own: <timestamp>-ElevenLabs.mp3) older than mp3KeepDays
CJSpeak_Cleanup(cfg){
	if !cfg.keep || !InStr(FileExist(cfg.dir), "D")
		return
	cutoff := A_Now
	EnvAdd, cutoff, % -cfg.keep, Days
	loop, Files, % cfg.dir "\*-ElevenLabs.mp3"
		if RegExMatch(A_LoopFileName, "^\d{8}-\d{6}(-\d+)?-ElevenLabs\.mp3$") && (A_LoopFileTimeModified < cutoff)
			FileDelete, %A_LoopFileFullPath%
}

CJSpeak_CleanupTick:
	CJSpeak_Cleanup(CJSpeak_Config())
	return

; usage of the current month from the log: {chars, requests, cached}
CJSpeak_LogStats(dir){
	st := {chars: 0, requests: 0, cached: 0}
	FileRead, log, % CJSpeak_LogPath(dir)
	if ErrorLevel
		return st
	month := SubStr(A_Now, 1, 4) "-" SubStr(A_Now, 5, 2)
	loop, parse, log, `n, `r
	{
		col := StrSplit(A_LoopField, ";")
		if (SubStr(col[1], 1, 7) != month)
			continue
		if (col[7] = "OK")
			st.chars += col[3], st.requests++
		else if (col[7] = "Cache")
			st.cached++
	}
	return st
}

; used / available characters of the account: {used, limit, reset (yyyyMMddHHmmss, local), err}
; needs the "User: Read" permission of the API key
CJSpeak_Quota(){
	key := CJSpeak_ApiKey()
	if (key = "")
		return {err: TXT.TIP_tts_nokey}
	try {
		req := ComObjCreate("WinHttp.WinHttpRequest.5.1")
		req.Open("GET", "https://api.elevenlabs.io/v1/user/subscription", false)
		req.SetTimeouts(5000, 5000, 10000, 10000)
		req.SetRequestHeader("xi-api-key", key)
		req.Send()
	} catch e
		return {err: e.Message}
	if (req.Status != 200)
		return {err: "HTTP " req.Status " " CJSpeak_ApiMessage(req)}
	body := req.ResponseText
	RegExMatch(body, """character_count""\s*:\s*(\d+)", u)
	RegExMatch(body, """character_limit""\s*:\s*(\d+)", l)
	reset := ""
	if RegExMatch(body, """next_character_count_reset_unix""\s*:\s*(\d+)", r) {
		reset := 1970
		EnvAdd, reset, % r1, Seconds 		; UTC
		utc := A_NowUTC
		EnvSub, utc, %A_Now%, Seconds 		; offset UTC - local
		EnvAdd, reset, % -utc, Seconds
	}
	return {used: u1, limit: l1, reset: reset}
}

; SHA-256 (hex) of the UTF-8 bytes of a string (CNG, Windows 10+)
CJSpeak_Sha256(str){
	n := StrPut(str, "UTF-8") - 1
	VarSetCapacity(buf, n + 1, 0) , StrPut(str, &buf, "UTF-8")
	if DllCall("bcrypt\BCryptOpenAlgorithmProvider", "Ptr*", hAlg, "WStr", "SHA256", "Ptr", 0, "UInt", 0)
		return ""
	VarSetCapacity(dig, 32, 0)
	r := DllCall("bcrypt\BCryptHash", "Ptr", hAlg, "Ptr", 0, "UInt", 0, "Ptr", &buf, "UInt", n, "Ptr", &dig, "UInt", 32)
	DllCall("bcrypt\BCryptCloseAlgorithmProvider", "Ptr", hAlg, "UInt", 0)
	if r
		return ""
	hex := ""
	loop 32
		hex .= Format("{:02x}", NumGet(dig, A_Index - 1, "UChar"))
	return hex
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

; <dir>\yyyyMMdd-HHmmss-ElevenLabs.mp3 (unique; no text in the name)
CJSpeak_FileName(dir){
	FormatTime, ts,, yyyyMMdd-HHmmss
	path := dir "\" ts "-ElevenLabs.mp3"
	while FileExist(path)
		path := dir "\" ts "-" (A_Index + 1) "-ElevenLabs.mp3"
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
