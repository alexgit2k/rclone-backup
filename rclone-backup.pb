; rclone-backup - Graphical user-interface for rclone
; 2021 by Alex
;
; rclone
; https://rclone.org/docs/
; https://rclone.org/flags/

; Config
Global rcloneConfig.s = "rclone.conf"
Global rcloneExe.s = "rclone.exe"
Global basePort = 5572
Global rcloneDaemon.s = "--rc-addr=localhost:" + basePort + " --rc-no-auth rcd"
; Config - GUI
Global winTitle.s = "rclone-backup"
Global winWidth = 250
Global winHeight = 215
Global fontName.s = "Segoe UI"
Global fontSize = 19
; Config - Misc
Global myConfig.s = GetFilePart(ProgramFilename(),#PB_FileSystem_NoExtension) + ".ini"
#Debug = #False
;DebugLevel 2

; Variables
Structure ListStructure
  List entries.s()
EndStructure
Global NewMap rclone.ListStructure()
Global NewMap Jobs.ListStructure()
Global NewMap JobsDetail.s()
Global ThreadMountStats, ThreadBackupStats, ThreadBackup

; Procedures
Declare rcloneStartRemote()
Declare.s rcloneAPI(command.s, param.s="", wait=#True, group.s="", ignoreErrors=#False)
Declare.s rcloneAPIGroup(command.s, index=0, wait = #True, group.s="", ignoreErrors=#False)
Declare rcloneConfig()

; Mid-level-routines
Declare readPreference()
Declare rcloneCheck()
Declare rcloneStats(*eta.Integer, *total.Integer, *done.Integer, group.s="")
Declare rclonePoll(*command.String)
Declare rcloneBackup(*dummy)
Declare rcloneClearCache(params.s)

; Low-level-routines
Declare.s combineParams(params.s)
Declare.s getParam(params.s, param.s)
Declare.s format(type.s, value1, value2=0)
Declare.i GetJSONValue(JSONString.s, key.s)
Declare.s GetJSONValueString(JSONString.s, key.s)

; GUI
Global WindowMain, InitText
Global ButtonMount, DropdownMountTargets, StatusMountQueueTitle, StatusMountTimeTitle, StatusMountQueue, StatusMountTime
Global ButtonBackup, DropdownBackupTargets, StatusBackupQueueTitle, StatusBackupTimeTitle, StatusBackupQueue, StatusBackupTime
Declare OpenWindowInit(font)
Declare OpenWindowStart()
Declare PopulateDropdown(gadget, List entries.s(), type.s)
XIncludeFile "bevelbutton.pb"
font = FontID( LoadFont(#PB_Any, fontName, fontSize, #PB_Font_HighQuality) )

; ------------------------------------------------------------------------------------------------------------

; Init
OpenWindowInit(font)
rcloneCheck()
readPreference()
rcloneStartRemote()
rcloneConfig()

; Start
OpenWindowStart()
Repeat
  Event = WaitWindowEvent()
  
  If Event = #PB_Event_Gadget
    Select BevelButton::GetButton(EventGadget())
      ; Mount
      Case ButtonMount
        Debug ""
        Debug "* Mount " + GetGadgetText(DropdownMountTargets) + " (" + Str(GetGadgetState(DropdownMountTargets)) + ")"
        ; Click changes state immediately, so check for state after click
        If BevelButton::GetState(ButtonMount) = #True
          ; Start mount
          DisableGadget(DropdownMountTargets, #True)
          BevelButton::Enable(ButtonMount)
          BevelButton::ColorDark(ButtonMount)
          If rcloneAPIGroup("mount", GetGadgetState(DropdownMountTargets), #True , "mount") = "Error"
            BevelButton::SetState(ButtonMount, #False)
            Continue
          EndIf
          ; Successfully mounted
          BevelButton::ColorNormal(ButtonMount)
          *threadMountCommand = @"mount"
          ThreadMountStats = CreateThread(@rclonePoll(), @*threadMountCommand)
        ; Unmount
        Else
          ; Transfer in progress
          ; Until better solution in https://github.com/rclone/rclone/issues/1909
          If GetGadgetText(StatusMountQueue) <> "-" Or GetGadgetText(StatusMountTime) <> "-"
            result = MessageRequester("Error", "Transfer is maybe still in progress!" + #CRLF$ + "Do you really want to unmount?", #PB_MessageRequester_YesNo)
            If result = #PB_MessageRequester_No
              BevelButton::SetState(ButtonMount, #True)
              Continue
            EndIf
          EndIf

          ; Stop mount and status-poll
          BevelButton::ColorDark(ButtonMount)
          If rcloneAPI("mount/unmountall") = "Error"
            BevelButton::ColorNormal(ButtonMount)
            BevelButton::SetState(ButtonMount, #True)
          Else
            BevelButton::Disable(ButtonMount)
          EndIf
          If IsThread(ThreadMountStats)
            KillThread(ThreadMountStats)
          EndIf
          SetGadgetText(StatusMountQueue, "-")
          SetGadgetText(StatusMountTime, "-")
          DisableGadget(DropdownMountTargets, #False)
        EndIf
        Continue
        
      ; Backup
      Case ButtonBackup
        Debug ""
        Debug "* Backup " + GetGadgetText(DropdownBackupTargets) + " (" + Str(GetGadgetState(DropdownBackupTargets)) + ")"
        ; Click changes state immediately, so check for state after click
        If BevelButton::GetState(ButtonBackup) = #True
          DisableGadget(DropdownBackupTargets, #True)
          BevelButton::Enable(ButtonBackup)
          BevelButton::ColorDark(ButtonBackup)
          rcloneAPIGroup("sync", GetGadgetState(DropdownBackupTargets), #False, "backup")
          *threadBackupCommand = @"backup"
          ThreadBackupStats = CreateThread(@rclonePoll(), @*threadBackupCommand)
          ThreadBackup = CreateThread(@rcloneBackup(), 0)
        ; Backup-Button is only disabled via Thread
        Else
          BevelButton::SetState(ButtonBackup, #True)
          BevelButton::Enable(ButtonBackup)
        EndIf
    EndSelect
  EndIf

  ; Minimize
  If Event = #PB_Event_MinimizeWindow
    HideWindow(WindowMain, #True)
  EndIf

  ; Systray
  If Event = #PB_Event_SysTray
    If IsWindowVisible_(WindowID(WindowMain))
      HideWindow(WindowMain, #True)
    Else
      HideWindow(WindowMain, #False)
      SetWindowState(WindowMain, #PB_Window_Normal)
    EndIf
  EndIf

  ; Close
  If Event = #PB_Event_CloseWindow
    ; Transfer in progress
    If BevelButton::GetState(ButtonBackup) = #True Or GetGadgetText(StatusMountQueue) <> "-" Or GetGadgetText(StatusMountTime) <> "-" Or GetGadgetText(StatusBackupQueue) <> "-" Or GetGadgetText(StatusBackupTime) <> "-"
      result = MessageRequester("Error", "Transfer is still in progress!" + #CRLF$ + "Do you really want to quit?", #PB_MessageRequester_YesNo)
      If result = #PB_MessageRequester_Yes
        Break
      EndIf      
      Continue
    EndIf
    ; End
    Break
  EndIf
ForEver 

; Prolog
rcloneAPI("mount/unmountall")
rcloneAPI("core/quit")
If IsThread(ThreadMountStats)
  KillThread(ThreadMountStats)
EndIf
If IsThread(ThreadBackupStats)
  KillThread(ThreadBackupStats)
EndIf
If IsThread(ThreadBackup)
  KillThread(ThreadBackup)
EndIf

End

; ------------------------------------------------------------------------------------------------------------

Procedure.s rcloneAPIGroup(command.s, index=0, wait = #True, group.s="", ignoreErrors=#False)
  Debug "- Starting rclone-commands '" + command + "'"
  Define params.s, result.s, i=0
  NewList commands.s()
  CopyList(rclone(command)\entries(), commands())
  
  ; Single item
  If index<>0
    SelectElement(commands(), index-1)
    item.s = commands()
    ClearList(commands())
    AddElement(commands()) 
    commands() = item
  EndIf
  
  ; Call API for all items in list
  ForEach commands()
    params = commands()
    ;Debug params
    result = rcloneAPI(command, params, wait, group, ignoreErrors)
    If result = "Error" : error=1 : EndIf
  Next
  
  If error=1
    ProcedureReturn "Error"
  EndIf
EndProcedure

Procedure.s rcloneAPI(command.s, param.s="", wait=#True, group.s="", ignoreErrors=#False)
  InitNetwork()
  Define response.s, error.s, status.s, url.s
  url = "http://localhost:" + basePort + "/" + command
  ; Expand command
  If FindString(command, "/") = 0
    url = url + "/" + command
  EndIf
  ; Asynchronous
  If wait = #False
    param = param + "&_async=true"
  EndIf
  ; Group
  If group <> ""
    param = param + "&_group=" + group
  EndIf
  Debug "- rcloneAPI: " + url + ", " + param
  ; Fetch data
  request = HTTPRequest(#PB_HTTP_Post, url, param)
  response = HTTPInfo(request, #PB_HTTP_Response)
  status = HTTPInfo(request, #PB_HTTP_StatusCode)
  error = HTTPInfo(request, #PB_HTTP_ErrorMessage)
  ; Handling
  If request And error="" And status="200"
    Debug "Status: " + status,2
    Debug "Response: " + response,2
  Else
    Debug "Request failed for " + url + " : " + error
    Debug "Response: " + response
    If ignoreErrors=#False
      MessageRequester("Error", "Request failed for " + url + " : " + error + #CRLF$ + response)
    EndIf
    response = "Error"
  EndIf
  FinishHTTP(request)
  
  ; Store job-ids
  If response <> "Error" And wait=#False
    id = GetJSONValue(response, "jobid")
    If id <> 0
      Debug "Getting jobid=" + Str(id) + " (" + command + ")"
      AddElement(Jobs(command)\entries())
      Jobs(command)\entries() = Str(id)
      JobsDetail(Str(id)) = param
    EndIf
  EndIf
  
  ProcedureReturn response
EndProcedure

Procedure rcloneStartRemote()
  ; Flags
  CompilerIf #Debug = #False
    Flags = #PB_Program_Hide
  CompilerElse
    Flags = 0
  CompilerEndIf
 
  ; Start rclone
  handle = RunProgram(rcloneExe, rcloneDaemon, "", Flags)
  If handle = 0
    MessageRequester("Error", "Unable to start rclone!")
    End
  EndIf

  ; Wait
  Define i, alive = 0, maxTries = 100
  For i=1 To maxTries
    Delay(100)
    Debug "Waiting for rclone (" + Str(i) + "/" + Str(maxTries) + ")"
    If rcloneAPI("rc/noop", "", #True, "", #True) = "{}" + #LF$
      alive = 1
      Break
    EndIf
  Next i
  If alive=0
    Debug "rclone not running!"
    MessageRequester("Error", "Unable to start rclone!")
    End
  EndIf
EndProcedure

Procedure rcloneConfig()
  Define result.s
  needsCreation = #False
  
  ; Check if rcloneConfig exists
  If (FileSize(rcloneConfig) = -1)
    Debug "- Creating '" + rcloneConfig + "', because it does not exist!"
    needsCreation = #True
  ; Check if own config has been updated
  ElseIf GetFileDate(rcloneConfig, #PB_Date_Modified) < GetFileDate(myConfig, #PB_Date_Modified)
    Debug "- Creating '" + rcloneConfig + "', because its older than '" + myConfig + "'!"
    If DeleteFile(rcloneConfig) = 0
      MessageRequester("Error","Unable to delete file: " + rcloneConfig)
      End
    EndIf
    needsCreation = #True
  EndIf

  ; Recreate rcloneConfig
  If needsCreation
    Debug "- Creating '" + rcloneConfig + "'"
    If CreateFile(0, rcloneConfig)
      CloseFile(0)
    Else
      MessageRequester("Error","Unable to create file: " + rcloneConfig)
      End
    EndIf
    
    ; Recreate config via rclone
    result = rcloneAPIGroup("config/create")
    If result = "Error"
      MessageRequester("Error","Unable to create config!")
      End
    EndIf
  EndIf
EndProcedure

Procedure rcloneStats(*eta.Integer, *total.Integer, *done.Integer, group.s="")
  Define response.s
  
  If group <> ""
    response = rcloneAPI("core/stats", "group=" + group)
  Else 
    response = rcloneAPI("core/stats")
  EndIf
  
  ; Get time & queue
  *eta\i = GetJSONValue(response,"eta")
  *total\i = GetJSONValue(response, "totalTransfers") + GetJSONValue(response, "totalChecks")
  *done\i = GetJSONValue(response, "transfers") + GetJSONValue(response, "checks")
EndProcedure

Procedure rclonePoll(*command.String)
  Repeat
    Define eta=0, total=0, done=0
  
    ; Filter backup-stats
    If *command\s = "mount"
      rcloneStats(@eta, @total, @done)
      SetGadgetText(StatusMountQueue, format("queue", done, total))
      SetGadgetText(StatusMountTime, format("time", eta))
    ElseIf *command\s = "backup"
      rcloneStats(@eta, @total, @done, "backup")
      SetGadgetText(StatusBackupQueue, format("queue", done, total))
      SetGadgetText(StatusBackupTime, format("time", eta))
    Else
      Debug "Unknown command " + *command\s
    EndIf
    
    Debug "- Statistics for " + *command\s + ": " + format("queue", done, total) + ", " + format("time", eta)
    
    ; Sleep
    Delay(1000)
    
    ; Do not update if window is invisible
    While IsWindowVisible_(WindowID(WindowMain)) = #False
      Delay(100)
    Wend
    
  ForEver
EndProcedure

Procedure rcloneBackup(*dummy)
  Define id.s, response.s, running, failed
  Repeat
    
    ; For all jobs
    Debug ""
    Debug "- Backup-Jobs to check: " + Str(ListSize(Jobs("sync")\entries()))
    running = 0
    failed = 0
    ForEach Jobs("sync")\entries()
      id = Jobs("sync")\entries()
      response.s = rcloneAPI("job/status","jobid="+id)
      ; Check job
      If GetJSONValue(response, "finished") = #True
        If GetJSONValue(response, "success") = #False
          Debug "Job " + id + " failed with: " + GetJSONValueString(response, "error")
          MessageRequester("Error", "Backup-Job failed with:" + #CRLF$ + GetJSONValueString(response, "error"))
          failed = 1
        Else
          Debug "Job " + id + " finished successfully"
        EndIf
        Debug "Job " + id + ": " + JobsDetail(id)
        DeleteElement(Jobs("sync")\entries())
        rcloneClearCache(JobsDetail(id))
        DeleteMapElement(JobsDetail(), id)
      Else
        Debug "Job " + id + " stil running"
        running = 1
      EndIf
    Next
    
    ; Reset on exit
    If running=0
      Debug "All Backup-Jobs finished"
      If failed=0
        rcloneAPI("core/stats-reset","group=backup")
      EndIf
      ; Enable-Backup-Button and quit status-poll
      BevelButton::ColorDark(ButtonBackup)
      BevelButton::Disable(ButtonBackup)
      If IsThread(ThreadBackupStats)
        KillThread(ThreadBackupStats)
      EndIf
      SetGadgetText(StatusBackupQueue, "-")
      SetGadgetText(StatusBackupTime, "-")
      DisableGadget(DropdownBackupTargets, #False)
      Break
    Else
      Debug "Backup-Jobs still running: " + Str(ListSize(Jobs("sync")\entries()))
    EndIf

    ; Sleep
    Delay(1000)
  ForEver
  
  Debug "Exiting rcloneBackup-Thread"
EndProcedure

Procedure rcloneClearCache(params.s)
  Define dstFs.s, fs.s, dir.s
  dstFs = getParam(params, "dstFs")
  If dstFs = ""
    Debug "Unable to find 'dstFs' in " + params
    ProcedureReturn
  EndIf
  fs = Mid(dstFs, 1, FindString(dstFs, ":"))
  dir = ReplaceString(dstFs, fs, "")
  Debug "Clearing cache for fs=" + fs + ", dir=" + dir + " (" + dstFs + ")"
  If fs <> "" And dir <> ""
    ; Clear cache and forget errors because of unmounted filesystems
    rcloneAPI("vfs/forget", "fs=" + fs + "&dir=" + dir, #True, "", #True)
  EndIf
EndProcedure

Procedure OpenWindowInit(font)
  WindowMain = OpenWindow(#PB_Any, 0, 0, winWidth, winHeight, winTitle, #PB_Window_Invisible | #PB_Window_MinimizeGadget | #PB_Window_SystemMenu | #PB_Window_TitleBar | #PB_Window_ScreenCentered)
  StickyWindow(WindowMain, #True)

  InitText = TextGadget(#PB_Any, 0, 82, winWidth, 50, "Initializing ...", #PB_Text_Center)
  SetGadgetFont(InitText, font)
  
  ; Buttons
  ButtonMount = BevelButton::New(10, 10, 230, 60, 0, "Mount", font, #PB_Button_Toggle)
  DropdownMountTargets = ComboBoxGadget(#PB_Any, 10, 70, 230, 21)
  ButtonBackup = BevelButton::New(10, 110, 230, 60, 0, "Backup", font, #PB_Button_Toggle)
  DropdownBackupTargets = ComboBoxGadget(#PB_Any, 10, 170, 230, 21)
  
  ; Status-texts
  StatusMountQueueTitle = TextGadget(#PB_Any, 10, 91, 45, 20, "Queue:")
  StatusMountQueue = TextGadget(#PB_Any, 50, 91, 70, 20, "-")
  StatusMountTimeTitle = TextGadget(#PB_Any, 130, 91, 60, 20, "Remaining:")
  StatusMountTime = TextGadget(#PB_Any, 195, 91, 45, 20, "-")  
  StatusBackupQueueTitle = TextGadget(#PB_Any, 10, 191, 45, 20, "Queue:")
  StatusBackupQueue = TextGadget(#PB_Any, 50, 191, 70, 20, "-")
  StatusBackupTimeTitle = TextGadget(#PB_Any, 130, 191, 60, 20, "Remaining:")
  StatusBackupTime = TextGadget(#PB_Any, 195, 191, 45, 20, "-")
  
  ; Hide & Disable
  BevelButton::Hide(ButtonMount)
  BevelButton::Hide(ButtonBackup)
  HideGadget(DropdownMountTargets, 1)
  HideGadget(DropdownBackupTargets, 1)
  HideGadget(StatusMountQueueTitle, 1)
  HideGadget(StatusMountQueue, 1)
  HideGadget(StatusMountTimeTitle, 1)
  HideGadget(StatusMountTime, 1)
  HideGadget(StatusBackupQueueTitle, 1)
  HideGadget(StatusBackupQueue, 1)
  HideGadget(StatusBackupTimeTitle, 1)
  HideGadget(StatusBackupTime, 1)

  ; Display Window
  HideWindow(WindowMain, 0)
  UpdateWindow_(WindowID(WindowMain))
  
  ; Systray
  systray = AddSysTrayIcon(#PB_Any, WindowID(WindowMain), ExtractIcon_(#Null, ProgramFilename(), 0))
  SysTrayIconToolTip(systray, winTitle)
EndProcedure

Procedure OpenWindowStart()
  PopulateDropdown(DropdownMountTargets, rclone("mount")\entries(), "mount")
  PopulateDropdown(DropdownBackupTargets, rclone("sync")\entries(), "backup")
  FreeGadget(InitText)
  
  ; Show
  BevelButton::Show(ButtonMount)
  BevelButton::Show(ButtonBackup)
  HideGadget(DropdownMountTargets, 0)
  HideGadget(DropdownBackupTargets, 0)
  HideGadget(StatusMountQueueTitle, 0)
  HideGadget(StatusMountQueue, 0)
  HideGadget(StatusMountTimeTitle, 0)
  HideGadget(StatusMountTime, 0)
  HideGadget(StatusBackupQueueTitle, 0)
  HideGadget(StatusBackupQueue, 0)
  HideGadget(StatusBackupTimeTitle, 0)
  HideGadget(StatusBackupTime, 0)

  UpdateWindow_(WindowID(WindowMain))
EndProcedure

; ------------------------------------------------------------------------------------------------------------
; Mid-level routines

Procedure readPreference()
  ; Open Preferences
  If (OpenPreferences(myConfig) = 0)
    MessageRequester("Error", "Can not open ini-file: "+myConfig)
    End
  EndIf
  
  ; Read
  ExaminePreferenceGroups()
  While NextPreferenceGroup()
    ExaminePreferenceKeys()
    While NextPreferenceKey()
      ; Concat if line contains "="
      command.s = PreferenceKeyName() + "=" + PreferenceKeyValue()
      If PreferenceKeyValue() <> ""
        command.s = PreferenceKeyName() + "=" + PreferenceKeyValue()
      Else
        command.s = PreferenceKeyName()
      EndIf
      
      ; Store
      command = ReplaceString(command, "&", "%26")
      command = combineParams(command)
      Debug PreferenceGroupName() + ": " + command
      AddElement(rclone(PreferenceGroupName())\entries())
      rclone(PreferenceGroupName())\entries() = command
    Wend
  Wend

  ; Close
  ClosePreferences()
EndProcedure

Procedure PopulateDropdown(gadget, List entries.s(), type.s)
  Define dropdownMaxlen = 40
  Define entry.s
  AddGadgetItem(gadget, 0, "All")
  ForEach entries()
    params.s = entries()
    Select type
      Case "mount"
        entry = getParam(params, "mountPoint") + " (" + getParam(params, "fs") + ")"
      Case "backup"
        entry = getParam(params, "dstFs")
      Default
        entry = "Unknown type '" + type + "'"
    EndSelect
    
    ; Shorten length
    If Len(entry) > dropdownMaxlen
      entry = "..." + Right(entry,dropdownMaxlen-3)
    EndIf
    AddGadgetItem(gadget, -1, entry)
  Next
  SetGadgetState(gadget, 0)  
EndProcedure

Procedure rcloneCheck()
  If (FileSize(rcloneExe) = -1)
    MessageRequester(winTitle + " - Error", rcloneExe + " is missing!" + #CRLF$ + "Download and place rclone.exe in same directory!")
    RunProgram("https://rclone.org/downloads/")
    End
  EndIf
EndProcedure

; ------------------------------------------------------------------------------------------------------------
; Low-level routines

Procedure.s combineParams(params.s)
  Define result.s, char.s, inQuotes=0, inBrackets=0
  For i=1 To Len(params)
    char = Mid(params,i,1)
    ; Replace space when not in quotes, encode in curly brackets
    If inQuotes = 0
      If char = Chr(34) : inQuotes = 1 : EndIf
      If inBrackets = 0 And char = "{" : inBrackets = 1
      ElseIf inBrackets = 1 And char = "}" : inBrackets = 0
      ElseIf inBrackets = 0 And char = " " : char = "&"
      ElseIf inBrackets = 1 And char = " " : char = "%20"
      ElseIf inBrackets = 0 And char = Chr(34) : char = "" ; Remove quotes except in JSON
      EndIf
    ; In quotes
    Else
      If char = Chr(34) : inQuotes = 0 : EndIf
      If inBrackets = 0 And char = Chr(34) : char = "" : EndIf ; Remove quotes except in JSON
      ;If char = " " : char = "%20" : EndIf
    EndIf
      
    result = result + char
  Next
  ProcedureReturn result
EndProcedure

Procedure.s getParam(params.s, param.s)
  Define result.s
  startPos = FindString(params, param+"=")
  If startPos = 0
    ProcedureReturn "Parameter '" + param + "' not found!"
  EndIf
  startPos = startPos + Len(param)+1
  If Mid(params,startPos,1)=Chr(34)
    startPos = startPos + 1
    endPos = FindString(params, Chr(34), startPos)
  ElseIf Mid(params,pos,1)="{"
    startPos = startPos + 1
    endPos = FindString(params, "}", startPos)
  Else
    endPos = FindString(params, "&", startPos)
  EndIf
  
  If endPos = 0 : endPos = Len(params) : EndIf
  result = Mid(params, startPos, endPos-startPos)
  result = ReplaceString(result, "%20", " ")
  
  ProcedureReturn result
EndProcedure

Procedure.s format(type.s, value1, value2=0)
  Define formatted.s, min.i, sec.i
  If value1=0 : ProcedureReturn "-" : EndIf
  
  Select type
    Case "time"
      min = value1/60
      sec = value1-min*60
      formatted = Str(min) + ":"
      If sec<10 : formatted = formatted + "0" : EndIf
      formatted = formatted + Str(sec)

    Case "queue"
      If value1 = value2
        formatted = "-"
      Else
        formatted = Str(value1) + " / " + Str(value2)
      EndIf
  EndSelect

  ProcedureReturn formatted
EndProcedure

Procedure.i GetJSONValue(JSONString.s, key.s)
  Define value = 0
  JSON = ParseJSON(#PB_Any, JSONString)
  If JSON=0 : ProcedureReturn 0 : EndIf
  entry = GetJSONMember(JSONValue(JSON), key)
  If entry <> 0
    Select JSONType(entry)
      Case #PB_JSON_Null:     Debug "Null for key " + key,3    : value = 0
      Case #PB_JSON_String:   Debug "String for key " + key,3  : value = Val(GetJSONString(entry))
      Case #PB_JSON_Number:   Debug "Number for key " + key,3  : value = GetJSONInteger(entry)
      Case #PB_JSON_Boolean:  Debug "Boolean for key " + key,3 : value = GetJSONBoolean(entry)
      Case #PB_JSON_Array:    Debug "Array for key " + key,3   : value = JSONArraySize(entry)
      Case #PB_JSON_Object:   Debug "Object for key " + key,3
      Default:                Debug "Unknown Type for key " + key,3
    EndSelect
  EndIf
  ;Debug key + " = " + value
  ProcedureReturn value
EndProcedure


Procedure.s GetJSONValueString(JSONString.s, key.s)
  Define value.s = ""
  JSON = ParseJSON(#PB_Any, JSONString)
  If JSON=0 : ProcedureReturn "" : EndIf
  entry = GetJSONMember(JSONValue(JSON), key)
  If entry <> 0
    Select JSONType(entry)
      Case #PB_JSON_Null:     Debug "Null for key " + key,3    : value = ""
      Case #PB_JSON_String:   Debug "String for key " + key,3  : value = GetJSONString(entry)
      Case #PB_JSON_Number:   Debug "Number for key " + key,3  : value = Str(GetJSONInteger(entry))
      Case #PB_JSON_Boolean:  Debug "Boolean for key " + key,3 : value = Str(GetJSONBoolean(entry))
      Case #PB_JSON_Array:    Debug "Array for key " + key,3   : value = Str(JSONArraySize(entry))
      Case #PB_JSON_Object:   Debug "Object for key " + key,3
      Default:                Debug "Unknown Type for key " + key,3
    EndSelect
  EndIf
  ;Debug key + " = " + value
  ProcedureReturn value
EndProcedure

; IDE Options = PureBasic 5.73 LTS (Windows - x86)
; CursorPosition = 20
; Folding = ----
; EnableThread
; EnableXP
; UseIcon = icon.ico
; Executable = rclone-backup.exe