# Lists every Windows function a program imports and fails when one of them
# does not exist on Windows 7 SP1. Run it on the finished EXE:
#
#   powershell -File tools\check-win7-imports.ps1 -Exe target\x86_64-win7-windows-msvc\release\EzooDownload.exe
#
# It reads the PE import tables itself (nothing to install). Exit code 1 =
# at least one import is missing on Windows 7.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [switch]$Quiet
)
$ErrorActionPreference = "Stop"
$b = [IO.File]::ReadAllBytes((Resolve-Path $Exe).Path)
function U16([int]$o) { [int][BitConverter]::ToUInt16($b, $o) }
function U32([int]$o) { [int64][BitConverter]::ToUInt32($b, $o) }
function U64([int]$o) { [BitConverter]::ToUInt64($b, $o) }

$pe = [int](U32 0x3C)
if ((U32 $pe) -ne 0x4550) { throw "$Exe is not a PE file" }
$nsec = U16 ($pe + 6)
$optSize = U16 ($pe + 20)
$opt = $pe + 24
$is64 = (U16 $opt) -eq 0x20b
$dd = if ($is64) { $opt + 112 } else { $opt + 96 }
$thunk = if ($is64) { 8 } else { 4 }

$sections = @()
for ($i = 0; $i -lt $nsec; $i++) {
    $s = $opt + $optSize + 40 * $i
    $sections += [pscustomobject]@{ VA = (U32 ($s + 12)); Size = [Math]::Max((U32 ($s + 8)), (U32 ($s + 16))); Raw = (U32 ($s + 20)) }
}
function Off([int64]$rva) {
    foreach ($s in $sections) { if ($rva -ge $s.VA -and $rva -lt ($s.VA + $s.Size)) { return [int]($rva - $s.VA + $s.Raw) } }
    return -1
}
function Str([int]$off) {
    $e = $off
    while ($b[$e] -ne 0) { $e++ }
    [Text.Encoding]::ASCII.GetString($b, $off, $e - $off)
}

# every (dll, function) pair, from the normal and the delay-load import tables
$imports = New-Object System.Collections.Generic.List[object]
function ReadThunks([string]$dll, [int64]$tableRva) {
    $o = Off $tableRva
    if ($o -lt 0) { return }
    while ($true) {
        $v = if ($is64) { U64 $o } else { U32 $o }
        if ($v -eq 0) { break }
        $isOrdinal = if ($is64) { $v -ge [uint64]9223372036854775808 } else { $v -ge 2147483648 }
        if ($isOrdinal) {
            $imports.Add([pscustomobject]@{ Dll = $dll; Func = "#" + ($v -band 0xFFFF) })
        } else {
            $n = Off ([int64]$v)
            if ($n -ge 0) { $imports.Add([pscustomobject]@{ Dll = $dll; Func = (Str ($n + 2)) }) }
        }
        $o += $thunk
    }
}
$impRva = U32 ($dd + 8)
if ($impRva -ne 0) {
    $d = Off $impRva
    while ((U32 ($d + 12)) -ne 0) {
        $dll = (Str (Off (U32 ($d + 12)))).ToLower()
        $names = U32 $d
        if ($names -eq 0) { $names = U32 ($d + 16) }
        ReadThunks $dll $names
        $d += 20
    }
}
$delayRva = U32 ($dd + 13 * 8)
if ($delayRva -ne 0) {
    $d = Off $delayRva
    while ((U32 ($d + 4)) -ne 0) {
        $dll = (Str (Off (U32 ($d + 4)))).ToLower()
        ReadThunks $dll (U32 ($d + 16))
        $d += 32
    }
}

# What Windows 7 SP1 does NOT have (function = since which Windows)
$missing = @{
    "bcryptprimitives.dll"           = @("ProcessPrng")                                  # Windows 10
    "kernel32.dll"                   = @("GetSystemTimePreciseAsFileTime",               # 8
                                         "PrefetchVirtualMemory", "SetThreadDescription", # 8 / 10 1607
                                         "GetThreadDescription", "GetTempPath2W",         # 10 1607 / 11
                                         "CreateFile2", "SetProcessMitigationPolicy")     # 8
    "user32.dll"                     = @("GetDpiForWindow", "GetDpiForSystem", "SetProcessDpiAwarenessContext",
                                         "EnableNonClientDpiScaling", "AdjustWindowRectExForDpi",
                                         "GetSystemMetricsForDpi", "GetAwarenessFromDpiAwarenessContext",
                                         "SetProcessDpiAwarenessContext")                # 8.1 / 10
    "shcore.dll"                     = @("*")                                            # 8.1 (the Windows 7 copy is almost empty)
    "api-ms-win-core-synch-l1-2-0.dll" = @("*")                                          # WaitOnAddress / WakeByAddress: 8
    "uiautomationcore.dll"           = @("UiaRaiseNotificationEvent", "UiaRaiseActiveTextPositionChangedEvent") # 10
}
$bad = @()
foreach ($i in $imports) {
    $list = $missing[$i.Dll]
    if ($list -and (($list -contains "*") -or ($list -contains $i.Func))) { $bad += "$($i.Dll)!$($i.Func)" }
}
$apiSets = $imports | Where-Object { $_.Dll -like "api-ms-win-*" } | Select-Object -ExpandProperty Dll -Unique

if (-not $Quiet) {
    Write-Host "Imported DLLs:"
    $imports | Group-Object Dll | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-45} {1} functions" -f $_.Name, $_.Count) }
}
if ($apiSets) {
    Write-Host "NOTE: these 'api-ms-win-*' contracts are imported. Windows 7 only has some of them;" -ForegroundColor Yellow
    Write-Host "      test the program on a real Windows 7 if this list is not empty:" -ForegroundColor Yellow
    $apiSets | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "NOT available on Windows 7:" -ForegroundColor Red
    $bad | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "OK: no import of a function that Windows 7 SP1 is missing (known list)." -ForegroundColor Green
exit 0
