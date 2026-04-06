param(
    [string]$Lua,
    [switch]$Raw,
    [string]$PipeName = "LuaHookV1",
    [int]$TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IpcMagic = 0x3241554c
$IpcVersion = 1

$IpcOperationEnqueue = 1
$IpcOperationQuery = 2

$IpcStatusOk = 0

$CommandStateQueued = 1
$CommandStateRunning = 2
$CommandStateDone = 3
$CommandStateFailed = 4
$CommandStateDropped = 5

$PayloadKindNone = 0
$PayloadKindRawLua = 1
$PayloadKindResultText = 2
$PayloadKindErrorText = 3

function Read-ExactBytes {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) {
            throw "Pipe closed while reading $Count bytes."
        }
        $offset += $read
    }

    return $buffer
}

function Invoke-PipeRequest {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Operation,
        [uint64]$CommandId = 0,
        [uint64]$GenerationId = 0,
        [byte[]]$Payload = @(),
        [int]$ConnectTimeoutMs = 3000
    )

    $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect($ConnectTimeoutMs)

        $writer = New-Object System.IO.BinaryWriter($client, [System.Text.Encoding]::UTF8, $true)
        $writer.Write([uint32]$IpcMagic)
        $writer.Write([uint32]$IpcVersion)
        $writer.Write([uint32]$Operation)
        $writer.Write([uint32]0)
        $writer.Write([uint64]$CommandId)
        $writer.Write([uint64]$GenerationId)
        $writer.Write([uint32]$Payload.Length)
        $writer.Write([uint32]0)
        if ($Payload.Length -gt 0) {
            $writer.Write($Payload)
        }
        $writer.Flush()

        $headerBytes = Read-ExactBytes -Stream $client -Count 72
        $reader = New-Object System.IO.BinaryReader((New-Object System.IO.MemoryStream(,$headerBytes)))

        $response = [ordered]@{
            magic            = $reader.ReadUInt32()
            version          = $reader.ReadUInt32()
            status           = $reader.ReadUInt32()
            payload_kind     = $reader.ReadUInt32()
            command_id       = $reader.ReadUInt64()
            generation_id    = $reader.ReadUInt64()
            command_state    = $reader.ReadUInt32()
            boundary_kind    = $reader.ReadUInt32()
            enqueue_time_utc = $reader.ReadUInt64()
            dispatch_time_utc= $reader.ReadUInt64()
            finish_time_utc  = $reader.ReadUInt64()
            payload_size     = $reader.ReadUInt32()
            reserved         = $reader.ReadUInt32()
            payload          = ""
        }

        if ($response.magic -ne $IpcMagic -or $response.version -ne $IpcVersion) {
            throw "Invalid IPC response header."
        }

        if ($response.payload_size -gt 0) {
            $payloadBytes = Read-ExactBytes -Stream $client -Count ([int]$response.payload_size)
            $response.payload = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
        }

        return [pscustomobject]$response
    } finally {
        $client.Dispose()
    }
}

function Get-CommandStateName {
    param([uint32]$State)

    switch ($State) {
        $CommandStateQueued { return "queued" }
        $CommandStateRunning { return "running" }
        $CommandStateDone { return "done" }
        $CommandStateFailed { return "failed" }
        $CommandStateDropped { return "dropped" }
        default { return "unknown" }
    }
}

function Get-PayloadKindName {
    param([uint32]$Kind)

    switch ($Kind) {
        $PayloadKindNone { return "none" }
        $PayloadKindRawLua { return "raw_lua" }
        $PayloadKindResultText { return "result_text" }
        $PayloadKindErrorText { return "error_text" }
        default { return "unknown" }
    }
}

function Test-IsTerminalState {
    param([uint32]$State)

    return $State -eq $CommandStateDone -or $State -eq $CommandStateFailed -or $State -eq $CommandStateDropped
}

function Build-FriendlyChunk {
    param([Parameter(Mandatory = $true)][string]$RawLua)

    return @"
local __phase2_results = table.pack((function()
$RawLua
end)())
if __phase2_results.n == 0 then return "<no values>" end
local __phase2_out = {}
for __phase2_i = 1, __phase2_results.n do
  __phase2_out[__phase2_i] = tostring(__phase2_results[__phase2_i])
end
return table.concat(__phase2_out, "\t")
"@
}

function Submit-Lua {
    param(
        [Parameter(Mandatory = $true)][string]$LuaSource,
        [switch]$UseRaw
    )

    $finalLua = if ($UseRaw) { $LuaSource } else { Build-FriendlyChunk -RawLua $LuaSource }
    $payload = [System.Text.Encoding]::UTF8.GetBytes($finalLua)

    $enqueue = Invoke-PipeRequest -Operation $IpcOperationEnqueue -Payload $payload
    if ($enqueue.status -ne $IpcStatusOk -or $enqueue.command_id -eq 0) {
        throw "Enqueue failed. IPC status=$($enqueue.status)"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 10
        $query = Invoke-PipeRequest -Operation $IpcOperationQuery -CommandId $enqueue.command_id
        if ($query.status -ne $IpcStatusOk) {
            continue
        }

        if (Test-IsTerminalState -State $query.command_state) {
            return $query
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for command $($enqueue.command_id)."
}

function Show-Result {
    param(
        [Parameter(Mandatory = $true)]$Result
    )

    $stateName = Get-CommandStateName -State $Result.command_state
    $payloadKindName = Get-PayloadKindName -Kind $Result.payload_kind
    Write-Host ("command_id={0} state={1} payload_kind={2}" -f $Result.command_id, $stateName, $payloadKindName)

    if (-not [string]::IsNullOrEmpty($Result.payload)) {
        Write-Host $Result.payload
    } elseif ($Result.command_state -eq $CommandStateDone) {
        Write-Host "<empty result>"
    }
}

function Show-Help {
    Write-Host "Commands:"
    Write-Host "  :quit        exit"
    Write-Host "  :help        show this help"
    Write-Host "  :raw <lua>   send the Lua chunk without result-stringifying wrapper"
    Write-Host "  any other line is wrapped so returned values are converted to text"
}

if ($PSBoundParameters.ContainsKey("Lua")) {
    $result = Submit-Lua -LuaSource $Lua -UseRaw:$Raw
    Show-Result -Result $result
    return
}

Write-Host "lua_hookv1 PowerShell REPL connected to \\.\pipe\$PipeName"
Show-Help

while ($true) {
    $line = Read-Host "lua"
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    switch ($line) {
        ":quit" { break }
        ":exit" { break }
        ":help" {
            Show-Help
            continue
        }
    }

    $useRaw = $false
    $luaSource = $line
    if ($line.StartsWith(":raw ")) {
        $useRaw = $true
        $luaSource = $line.Substring(5)
    }

    try {
        $result = Submit-Lua -LuaSource $luaSource -UseRaw:$useRaw
        Show-Result -Result $result
    } catch {
        Write-Host $_.Exception.Message
    }
}
