param(
    [string]$LeftPath = (Get-Location).ProviderPath,
    [string]$RightPath = (Get-Location).ProviderPath,
    [switch]$NoColor,
    [switch]$Ascii,
    [string]$LogPath,
    [string]$ConfigPath,
    [string]$OwnerName,
    [string]$OwnerEmail,
    [switch]$RunSelfTest,
    [switch]$SafeDelete,
    [switch]$MouseDiagnostics,
    [switch]$InputParserSelfTest,
    [switch]$Help
)

$ErrorActionPreference = 'Continue'

# English: Application constants and global state.
# Magyar: Alkalmazas konstansok es globalis allapot.
$script:ApplicationName = 'console_commander'
$script:AppMetadata = @{
    Name = 'console_commander'
    Version = '0.7.0'
    OwnerName = 'Zolnai Zsolt'
    OwnerEmail = 'zzsolt@gmail.com'
    Repository = 'https://github.com/zzsolt/console_commander'
    Description = 'Console-only dual-pane file manager for Windows PowerShell'
}
$script:DriveProviderPath = '__CONSOLE_COMMANDER_DRIVES__'
$script:InternalClipboard = @()
$script:ZipAssembliesLoaded = $false
$script:OriginalForeground = $null
$script:OriginalBackground = $null
$script:OriginalConsoleMode = $null
$script:ConsoleInputHandle = [IntPtr]::Zero
$script:MouseInputAvailable = $false
$script:MouseUnavailableReason = ''
$script:InputModePreference = 'Auto'
$script:MouseBackend = 'KeyboardOnly'
$script:MouseBackendRequested = 'Auto'
$script:HostKind = 'Unknown'
$script:VtMouseEnabled = $false
$script:MouseEventMonitorEnabled = $false
$script:PendingInputEvents = New-Object System.Collections.Queue
$script:LastCommandLineOutput = @()
$script:UiTheme = $null
$script:MouseDiagnosticsState = $null
$script:LastMouseClick = $null
$script:MouseClickSequence = 0
$script:NonInteractiveMode = $false
$script:CurrentDialogMessage = ''
$script:RenderState = @{
    FullRedrawRequired = $true
    LastWidth = 0
    LastHeight = 0
    LineCache = @{}
    TopMenuZones = @()
    LeftPanelZone = $null
    RightPanelZone = $null
    DialogButtonZones = @()
    DropdownZones = @()
    DropdownMenuIndex = -1
    OpenTopMenuIndex = -1
    LastLayout = $null
}

function Get-UsableBasePath {
    param(
        [string]$Preferred,
        [string]$Fallback
    )

    if ([string]::IsNullOrWhiteSpace($Preferred)) {
        if ([string]::IsNullOrWhiteSpace($Fallback)) {
            return [System.IO.Path]::GetTempPath()
        }
        return $Fallback
    }

    return $Preferred
}

function New-DirectoryIfMissing {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop)
    }
}

function Initialize-ApplicationPaths {
    $localBase = Get-UsableBasePath -Preferred $env:LOCALAPPDATA -Fallback $env:TEMP
    $roamingBase = Get-UsableBasePath -Preferred $env:APPDATA -Fallback $env:TEMP

    $script:LocalDataPath = Join-Path -Path $localBase -ChildPath 'ConsoleCommander'
    $script:RoamingDataPath = Join-Path -Path $roamingBase -ChildPath 'ConsoleCommander'
    New-DirectoryIfMissing -Path $script:LocalDataPath
    New-DirectoryIfMissing -Path $script:RoamingDataPath

    if ([string]::IsNullOrWhiteSpace($script:EffectiveLogPath)) {
        $script:EffectiveLogPath = Join-Path -Path $script:LocalDataPath -ChildPath 'console_commander.log'
    }

    if ([string]::IsNullOrWhiteSpace($script:EffectiveConfigPath)) {
        $script:EffectiveConfigPath = Join-Path -Path $script:RoamingDataPath -ChildPath 'config.json'
    }

    $logParent = Split-Path -Path $script:EffectiveLogPath -Parent
    $configParent = Split-Path -Path $script:EffectiveConfigPath -Parent
    New-DirectoryIfMissing -Path $logParent
    New-DirectoryIfMissing -Path $configParent
}

function Write-AppLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    try {
        if ([string]::IsNullOrWhiteSpace($script:EffectiveLogPath)) {
            return
        }

        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = '{0} [{1}] {2}' -f $timestamp, $Level, $Message
        Add-Content -LiteralPath $script:EffectiveLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Verbose ('Log write failed: {0}' -f $_.Exception.Message)
    }
}

function Convert-ObjectToHashtable {
    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = Convert-ObjectToHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(Convert-ObjectToHashtable -InputObject $item)
        }
        return $items
    }

    if ($InputObject.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = Convert-ObjectToHashtable -InputObject $property.Value
        }
        return $result
    }

    return $InputObject
}

function Merge-HashtableDefaults {
    param(
        [hashtable]$Target,
        [hashtable]$Defaults
    )

    foreach ($key in $Defaults.Keys) {
        if (-not $Target.ContainsKey($key)) {
            $Target[$key] = $Defaults[$key]
        }
        elseif (($Target[$key] -is [System.Collections.IDictionary]) -and ($Defaults[$key] -is [System.Collections.IDictionary])) {
            Merge-HashtableDefaults -Target $Target[$key] -Defaults $Defaults[$key]
        }
    }

    return $Target
}

function Get-AppMetadataValue {
    param(
        [string]$Name
    )

    if ($script:AppMetadata.ContainsKey($Name)) {
        return [string]$script:AppMetadata[$Name]
    }
    return ''
}

function Get-AppOwnerName {
    if ($null -ne $script:Config -and -not [string]::IsNullOrWhiteSpace([string]$script:Config.OwnerName)) {
        return [string]$script:Config.OwnerName
    }
    return Get-AppMetadataValue -Name 'OwnerName'
}

function Get-AppOwnerEmail {
    if ($null -ne $script:Config -and -not [string]::IsNullOrWhiteSpace([string]$script:Config.OwnerEmail)) {
        return [string]$script:Config.OwnerEmail
    }
    return Get-AppMetadataValue -Name 'OwnerEmail'
}

function Get-AppRuntimeText {
    $psVersion = [string]$PSVersionTable.PSVersion
    $hostName = [string]$Host.Name
    if ([string]::IsNullOrWhiteSpace($psVersion)) {
        $psVersion = 'Unknown'
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $hostName = 'Unknown'
    }
    return ('Windows PowerShell {0}; Host: {1}; Console: {2}' -f $psVersion, $script:HostKind, $hostName)
}

function Get-OwnerTopBarTextCandidates {
    $name = Get-AppOwnerName
    $email = Get-AppOwnerEmail
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($email)) {
        $candidates += ('Owner: {0} <{1}>' -f $name, $email)
        $candidates += ('{0} <{1}>' -f $name, $email)
        $candidates += $name
    }
    elseif (-not [string]::IsNullOrWhiteSpace($name)) {
        $candidates += ('Owner: {0}' -f $name)
        $candidates += $name
    }
    elseif (-not [string]::IsNullOrWhiteSpace($email)) {
        $candidates += ('Owner: <{0}>' -f $email)
        $candidates += $email
    }

    $unique = @()
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $unique -notcontains $candidate) {
            $unique += $candidate
        }
    }
    return $unique
}

function Get-AboutLines {
    return @(
        (Get-AppMetadataValue -Name 'Name'),
        ('Version: {0}' -f (Get-AppMetadataValue -Name 'Version')),
        ('Owner: {0}' -f (Get-AppOwnerName)),
        ('Email: {0}' -f (Get-AppOwnerEmail)),
        ('Repository: {0}' -f (Get-AppMetadataValue -Name 'Repository')),
        ('Runtime: {0}' -f (Get-AppRuntimeText))
    )
}

function New-DefaultConfig {
    $userMenu = @(
        @{
            Name = 'Open PowerShell here'
            Type = 'Internal'
            Action = 'OpenShellHere'
        },
        @{
            Name = 'Calculate directory size'
            Type = 'Internal'
            Action = 'DirectorySize'
        },
        @{
            Name = 'Hash selected file SHA256'
            Type = 'Internal'
            Action = 'HashSha256'
        },
        @{
            Name = 'Compress to ZIP'
            Type = 'Internal'
            Action = 'ZipCreate'
        },
        @{
            Name = 'Extract ZIP'
            Type = 'Internal'
            Action = 'ZipExtract'
        },
        @{
            Name = 'Copy full path to internal clipboard'
            Type = 'Internal'
            Action = 'CopyFullPath'
        },
        @{
            Name = 'Show properties'
            Type = 'Internal'
            Action = 'Properties'
        }
    )

    return @{
        UseColor = $true
        UseAscii = $true
        ShowHidden = $false
        DirectoryFirst = $true
        SortBy = 'name'
        ReverseSort = $false
        SafeDelete = $false
        ConfirmCopy = $true
        ConfirmMove = $true
        ConfirmDelete = $true
        ConfirmExecute = $true
        DefaultEncoding = 'UTF8'
        CaseSensitiveSearch = $false
        MouseMode = 'Auto'
        CommandTimeoutSeconds = 60
        EditorTabSize = 4
        BorderStyle = 'ASCII'
        CompactMode = 'Auto'
        ColorTheme = 'Classic blue'
        VtMouseMode = $false
        OwnerName = (Get-AppMetadataValue -Name 'OwnerName')
        OwnerEmail = (Get-AppMetadataValue -Name 'OwnerEmail')
        Bookmarks = @()
        CommandHistory = @()
        PanelizeCommands = @()
        UserMenu = $userMenu
    }
}

function Load-AppConfig {
    $defaults = New-DefaultConfig
    $config = $defaults

    try {
        if (Test-Path -LiteralPath $script:EffectiveConfigPath -PathType Leaf) {
            $json = Get-Content -LiteralPath $script:EffectiveConfigPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $loaded = ConvertFrom-Json -InputObject $json -ErrorAction Stop
                $loadedTable = Convert-ObjectToHashtable -InputObject $loaded
                if ($loadedTable -is [System.Collections.IDictionary]) {
                    $config = Merge-HashtableDefaults -Target $loadedTable -Defaults $defaults
                }
            }
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ('Config load failed, defaults used: {0}' -f $_.Exception.Message)
        $config = $defaults
    }

    if ($NoColor.IsPresent) {
        $config.UseColor = $false
    }
    if ($Ascii.IsPresent) {
        $config.UseAscii = $true
    }
    if ($SafeDelete.IsPresent) {
        $config.SafeDelete = $true
    }

    return $config
}

function Save-AppConfig {
    try {
        $json = $script:Config | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $script:EffectiveConfigPath -Value $json -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Config save failed: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Normalize-UserMenu {
    param(
        [object[]]$Entries
    )

    $normalized = @()
    foreach ($entry in $Entries) {
        if ($null -eq $entry) {
            continue
        }
        $name = [string]$entry.Name
        $type = [string]$entry.Type
        $command = [string]$entry.Command
        if ($name -eq 'Open PowerShell here' -and $type -eq 'Command') {
            $normalized += @{
                Name = 'Open PowerShell here'
                Type = 'Internal'
                Action = 'OpenShellHere'
            }
            continue
        }
        if ($type -eq 'Command' -and $command -match '(?i)powershell(\.exe)?\s+.*-NoExit') {
            Write-AppLog -Level 'WARN' -Message ('Unsafe interactive default command removed from user menu: {0}' -f $name)
            continue
        }
        $normalized += $entry
    }
    return $normalized
}

function Initialize-ConfigRuntime {
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.MouseMode)) {
        $script:Config.MouseMode = 'Auto'
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.CommandTimeoutSeconds)) {
        $script:Config.CommandTimeoutSeconds = 60
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.EditorTabSize)) {
        $script:Config.EditorTabSize = 4
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.BorderStyle)) {
        $script:Config.BorderStyle = 'ASCII'
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.CompactMode)) {
        $script:Config.CompactMode = 'Auto'
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.ColorTheme)) {
        $script:Config.ColorTheme = 'Classic blue'
    }
    if ($Ascii.IsPresent) {
        $script:Config.BorderStyle = 'ASCII'
        $script:Config.UseAscii = $true
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.OwnerName)) {
        $script:Config.OwnerName = Get-AppMetadataValue -Name 'OwnerName'
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.OwnerEmail)) {
        $script:Config.OwnerEmail = Get-AppMetadataValue -Name 'OwnerEmail'
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerName)) {
        $script:Config.OwnerName = $OwnerName
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerEmail)) {
        $script:Config.OwnerEmail = $OwnerEmail
    }
    $normalizedMouseMode = [string]$script:Config.MouseMode
    if ($normalizedMouseMode -eq 'KeyboardOnly') {
        $normalizedMouseMode = 'Disabled'
    }
    if (@('Auto', 'Win32', 'VT', 'Disabled') -notcontains $normalizedMouseMode) {
        $normalizedMouseMode = 'Auto'
    }
    $script:Config.MouseMode = $normalizedMouseMode
    $script:InputModePreference = $normalizedMouseMode
    $script:MouseBackendRequested = $normalizedMouseMode
    $script:Config.UserMenu = @(Normalize-UserMenu -Entries $script:Config.UserMenu)
    Initialize-UiTheme
}

function Show-StartupHelp {
    $lines = @(
        'console_commander - console-only dual-pane file manager',
        '',
        'Usage:',
        '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 [options]',
        '',
        'Options:',
        '  -LeftPath <string>    Initial left panel path',
        '  -RightPath <string>   Initial right panel path',
        '  -NoColor             Disable console colors',
        '  -Ascii               Force ASCII borders',
        '  -LogPath <string>    Log file path',
        '  -ConfigPath <string> Config JSON path',
        '  -OwnerName <string>  Override owner display name for this run',
        '  -OwnerEmail <string> Override owner email for this run',
        '  -RunSelfTest         Run non-interactive smoke tests',
        '  -SafeDelete          Move deleted items to application trash when possible',
        '  -MouseDiagnostics    Show mouse input diagnostics and event test loop',
        '  -InputParserSelfTest Run non-interactive VT keyboard parser tests',
        '  -Help                Show this help',
        '',
        'Main keys:',
        '  Tab switch panel, Enter open/execute command, Backspace parent',
        '  F1 Help, F2 User menu, F3 View, F4 Edit, F5 Copy, F6 Move',
        '  F7 Mkdir, F8 Delete, F9 PullDn, F10 Quit'
    )
    foreach ($line in $lines) {
        Write-Output $line
    }
}

function Get-NormalizedPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return (Get-Location).ProviderPath
    }

    if ($Path -eq $script:DriveProviderPath) {
        return $script:DriveProviderPath
    }

    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        if ($resolved.Count -gt 0) {
            return $resolved[0].ProviderPath
        }
    }
    catch {
        try {
            return [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return $Path
        }
    }
}

function Get-PathForDisplay {
    param(
        [string]$Path
    )

    if ($Path -eq $script:DriveProviderPath) {
        return 'Computer'
    }
    return $Path
}

function New-FileItem {
    param(
        [string]$Name,
        [string]$FullName,
        [bool]$IsDirectory,
        [long]$Length,
        [datetime]$LastWriteTime,
        [System.IO.FileAttributes]$Attributes,
        [bool]$IsParent = $false,
        [bool]$IsDrive = $false,
        [bool]$IsVirtual = $false,
        [string]$SourceProvider = 'Local'
    )

    $extension = ''
    if (-not $IsDirectory -and -not $IsDrive) {
        $extension = [System.IO.Path]::GetExtension($Name)
    }

    return [pscustomobject]@{
        Name = $Name
        FullName = $FullName
        IsDirectory = $IsDirectory
        IsParent = $IsParent
        IsDrive = $IsDrive
        IsVirtual = $IsVirtual
        Length = $Length
        LastWriteTime = $LastWriteTime
        Attributes = $Attributes
        Extension = $extension
        SourceProvider = $SourceProvider
    }
}

function New-PanelState {
    param(
        [string]$Name,
        [string]$Path
    )

    $normalized = Get-NormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        $normalized = (Get-Location).ProviderPath
    }

    return @{
        Name = $Name
        Provider = 'Local'
        Path = $normalized
        ReturnPath = $normalized
        Items = @()
        VirtualItems = @()
        SelectedIndex = 0
        TopIndex = 0
        Marks = @{}
        History = @($normalized)
        HistoryIndex = 0
        FilterPattern = ''
        FilterRegex = $false
        CaseSensitive = $false
        Status = ''
    }
}

function Get-ShortAttributes {
    param(
        [System.IO.FileAttributes]$Attributes
    )

    $text = ''
    if (($Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { $text += 'D' } else { $text += '-' }
    if (($Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $text += 'R' } else { $text += '-' }
    if (($Attributes -band [System.IO.FileAttributes]::Archive) -ne 0) { $text += 'A' } else { $text += '-' }
    if (($Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0) { $text += 'H' } else { $text += '-' }
    if (($Attributes -band [System.IO.FileAttributes]::System) -ne 0) { $text += 'S' } else { $text += '-' }
    if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $text += 'L' } else { $text += '-' }
    return $text
}

function Format-FileSize {
    param(
        [long]$Length,
        [bool]$IsDirectory
    )

    if ($IsDirectory) {
        return '<DIR>'
    }

    if ($Length -lt 1024) {
        return $Length.ToString()
    }

    if ($Length -lt 1048576) {
        return ('{0:N1}K' -f ($Length / 1024))
    }

    if ($Length -lt 1073741824) {
        return ('{0:N1}M' -f ($Length / 1048576))
    }

    return ('{0:N1}G' -f ($Length / 1073741824))
}

function Truncate-Text {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($Width -le 0) {
        return ''
    }

    if ($null -eq $Text) {
        $Text = ''
    }

    if ($Text.Length -le $Width) {
        return $Text.PadRight($Width)
    }

    if ($Width -le 1) {
        return '>'
    }

    return ($Text.Substring(0, $Width - 1) + '>')
}

function Center-Text {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($null -eq $Text) { $Text = '' }
    $value = $Text
    if ($value.Length -gt $Width) {
        $value = Truncate-Text -Text $value -Width $Width
    }
    if ($value.Length -eq $Width) { return $value }
    $padding = $Width - $value.Length
    $leftPad = [int][Math]::Floor($padding / 2)
    $rightPad = $padding - $leftPad
    return ((' ' * $leftPad) + $value + (' ' * $rightPad))
}

function Sort-PanelItems {
    param(
        [object[]]$Items
    )

    $parentItems = @($Items | Where-Object { $_.IsParent })
    $normalItems = @($Items | Where-Object { -not $_.IsParent })

    $sortBy = [string]$script:Config.SortBy
    switch ($sortBy.ToLowerInvariant()) {
        'extension' { $sorted = @($normalItems | Sort-Object -Property @{Expression = 'Extension'; Ascending = $true}, @{Expression = 'Name'; Ascending = $true}) }
        'size' { $sorted = @($normalItems | Sort-Object -Property @{Expression = 'Length'; Ascending = $true}, @{Expression = 'Name'; Ascending = $true}) }
        'modified' { $sorted = @($normalItems | Sort-Object -Property @{Expression = 'LastWriteTime'; Ascending = $true}, @{Expression = 'Name'; Ascending = $true}) }
        'attributes' { $sorted = @($normalItems | Sort-Object -Property @{Expression = 'Attributes'; Ascending = $true}, @{Expression = 'Name'; Ascending = $true}) }
        default { $sorted = @($normalItems | Sort-Object -Property @{Expression = 'Name'; Ascending = $true}) }
    }

    if ($script:Config.DirectoryFirst) {
        $directories = @($sorted | Where-Object { $_.IsDirectory -or $_.IsDrive })
        $files = @($sorted | Where-Object { -not $_.IsDirectory -and -not $_.IsDrive })
        $sorted = @($directories + $files)
    }

    if ($script:Config.ReverseSort) {
        [array]::Reverse($sorted)
    }

    return @($parentItems + $sorted)
}

function Test-ItemVisibleByFilter {
    param(
        [object]$Item,
        [hashtable]$Panel
    )

    if ([string]::IsNullOrWhiteSpace($Panel.FilterPattern)) {
        return $true
    }

    if ($Item.IsParent) {
        return $true
    }

    $name = [string]$Item.Name
    $pattern = [string]$Panel.FilterPattern
    $options = [System.Text.RegularExpressions.RegexOptions]::None
    if (-not $Panel.CaseSensitive) {
        $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }

    if ($Panel.FilterRegex) {
        try {
            return [System.Text.RegularExpressions.Regex]::IsMatch($name, $pattern, $options)
        }
        catch {
            return $true
        }
    }

    if ($Panel.CaseSensitive) {
        return ($name -clike $pattern)
    }

    return ($name -like $pattern)
}

function Get-LocalPanelItems {
    param(
        [string]$Path,
        [hashtable]$Panel
    )

    $items = @()

    if ($Path -eq $script:DriveProviderPath) {
        try {
            $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction Stop | Sort-Object -Property Name)
            foreach ($drive in $drives) {
                if ([string]::IsNullOrWhiteSpace($drive.Root)) {
                    continue
                }
                $displayName = $drive.Root
                $items += ,(New-FileItem -Name $displayName -FullName $drive.Root -IsDirectory $true -Length 0 -LastWriteTime ([datetime]::MinValue) -Attributes ([System.IO.FileAttributes]::Directory) -IsDrive $true)
            }
        }
        catch {
            Write-AppLog -Level 'ERROR' -Message ('Drive listing failed: {0}' -f $_.Exception.Message)
        }
        return $items
    }

    try {
        $directory = Get-Item -LiteralPath $Path -ErrorAction Stop
        $parentPath = Split-Path -Path $directory.FullName -Parent
        if ([string]::IsNullOrWhiteSpace($parentPath)) {
            $parentPath = $script:DriveProviderPath
        }

        $items += ,(New-FileItem -Name '..' -FullName $parentPath -IsDirectory $true -Length 0 -LastWriteTime $directory.LastWriteTime -Attributes ([System.IO.FileAttributes]::Directory) -IsParent $true)

        if ($script:Config.ShowHidden) {
            $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        }
        else {
            $children = @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop | Where-Object {
                    (($_.Attributes -band [System.IO.FileAttributes]::Hidden) -eq 0) -and
                    (($_.Attributes -band [System.IO.FileAttributes]::System) -eq 0)
                })
        }

        foreach ($child in $children) {
            $isDirectory = (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            $length = 0
            if (-not $isDirectory) {
                $length = [long]$child.Length
            }

            $newItem = New-FileItem -Name $child.Name -FullName $child.FullName -IsDirectory $isDirectory -Length $length -LastWriteTime $child.LastWriteTime -Attributes $child.Attributes
            if (Test-ItemVisibleByFilter -Item $newItem -Panel $Panel) {
                $items += ,$newItem
            }
        }
    }
    catch {
        $Panel.Status = ('Cannot read directory: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('Directory listing failed for {0}: {1}' -f $Path, $_.Exception.Message)
    }

    return Sort-PanelItems -Items $items
}

function Refresh-Panel {
    param(
        [hashtable]$Panel
    )

    if ($Panel.Provider -eq 'Local') {
        $Panel.Items = @(Get-LocalPanelItems -Path $Panel.Path -Panel $Panel)
    }
    else {
        $Panel.Items = @(Sort-PanelItems -Items $Panel.VirtualItems)
    }

    if ($Panel.SelectedIndex -lt 0) {
        $Panel.SelectedIndex = 0
    }
    if ($Panel.SelectedIndex -ge $Panel.Items.Count) {
        $Panel.SelectedIndex = [Math]::Max(0, $Panel.Items.Count - 1)
    }
    if ($Panel.TopIndex -lt 0) {
        $Panel.TopIndex = 0
    }
    if ($Panel.TopIndex -gt $Panel.SelectedIndex) {
        $Panel.TopIndex = $Panel.SelectedIndex
    }
}

function Add-PanelHistory {
    param(
        [hashtable]$Panel,
        [string]$Path
    )

    if ($Panel.History.Count -gt 0 -and $Panel.HistoryIndex -ge 0 -and $Panel.History[$Panel.HistoryIndex] -eq $Path) {
        return
    }

    # English: New navigation after going back drops forward history, like a browser.
    # Magyar: Visszalepes utani uj navigacio torli az elore tortenetet, bongeszo modjara.
    if ($Panel.HistoryIndex -lt ($Panel.History.Count - 1)) {
        $trimmedHistory = @()
        for ($i = 0; $i -le $Panel.HistoryIndex; $i++) {
            $trimmedHistory += $Panel.History[$i]
        }
        $Panel.History = $trimmedHistory
    }

    $Panel.History += $Path
    $Panel.HistoryIndex = $Panel.History.Count - 1
}

function Set-PanelLocalPath {
    param(
        [hashtable]$Panel,
        [string]$Path,
        [bool]$AddHistory = $true
    )

    $normalized = Get-NormalizedPath -Path $Path
    if ($normalized -ne $script:DriveProviderPath -and -not (Test-Path -LiteralPath $normalized -PathType Container)) {
        $Panel.Status = ('Path not available: {0}' -f $Path)
        return $false
    }

    $Panel.Provider = 'Local'
    $Panel.Path = $normalized
    $Panel.ReturnPath = $normalized
    $Panel.VirtualItems = @()
    $Panel.SelectedIndex = 0
    $Panel.TopIndex = 0
    if ($AddHistory) {
        Add-PanelHistory -Panel $Panel -Path $normalized
    }
    Refresh-Panel -Panel $Panel
    return $true
}

# English: Navigate stored panel history without adding another history entry.
# Magyar: Paneltortenet lepkedese ujabb torteneti bejegyzes hozzaadasa nelkul.
function Move-PanelHistory {
    param(
        [hashtable]$Panel,
        [int]$Delta
    )

    if ($Panel.History.Count -le 1) {
        $Panel.Status = 'No panel history.'
        return $false
    }

    $targetIndex = [int]$Panel.HistoryIndex + $Delta
    if ($targetIndex -lt 0 -or $targetIndex -ge $Panel.History.Count) {
        $Panel.Status = 'No more panel history.'
        return $false
    }

    $targetPath = [string]$Panel.History[$targetIndex]
    if (-not (Set-PanelLocalPath -Panel $Panel -Path $targetPath -AddHistory $false)) {
        return $false
    }
    $Panel.HistoryIndex = $targetIndex
    $Panel.Status = ('History {0}/{1}' -f ($Panel.HistoryIndex + 1), $Panel.History.Count)
    return $true
}

function Set-PanelVirtualItems {
    param(
        [hashtable]$Panel,
        [string]$Provider,
        [string]$Title,
        [object[]]$Items,
        [string]$ReturnPath
    )

    if ([string]::IsNullOrWhiteSpace($ReturnPath)) {
        $ReturnPath = $Panel.Path
    }

    $Panel.Provider = $Provider
    $Panel.Path = $Title
    $Panel.ReturnPath = $ReturnPath
    $Panel.VirtualItems = @($Items)
    $Panel.Marks = @{}
    $Panel.SelectedIndex = 0
    $Panel.TopIndex = 0
    Refresh-Panel -Panel $Panel
}

function Get-ActivePanel {
    if ($script:State.ActivePanel -eq 'Left') {
        return $script:State.LeftPanel
    }
    return $script:State.RightPanel
}

function Get-PassivePanel {
    if ($script:State.ActivePanel -eq 'Left') {
        return $script:State.RightPanel
    }
    return $script:State.LeftPanel
}

function Get-CurrentItem {
    param(
        [hashtable]$Panel
    )

    if ($Panel.Items.Count -eq 0) {
        return $null
    }
    if ($Panel.SelectedIndex -lt 0 -or $Panel.SelectedIndex -ge $Panel.Items.Count) {
        return $null
    }
    return $Panel.Items[$Panel.SelectedIndex]
}

function Move-Selection {
    param(
        [hashtable]$Panel,
        [int]$Delta,
        [int]$VisibleRows
    )

    if ($Panel.Items.Count -eq 0) {
        return
    }

    $Panel.SelectedIndex += $Delta
    if ($Panel.SelectedIndex -lt 0) {
        $Panel.SelectedIndex = 0
    }
    if ($Panel.SelectedIndex -ge $Panel.Items.Count) {
        $Panel.SelectedIndex = $Panel.Items.Count - 1
    }

    if ($Panel.SelectedIndex -lt $Panel.TopIndex) {
        $Panel.TopIndex = $Panel.SelectedIndex
    }
    if ($VisibleRows -gt 0 -and $Panel.SelectedIndex -ge ($Panel.TopIndex + $VisibleRows)) {
        $Panel.TopIndex = $Panel.SelectedIndex - $VisibleRows + 1
    }
}

function Set-SelectionAbsolute {
    param(
        [hashtable]$Panel,
        [int]$Index,
        [int]$VisibleRows
    )

    if ($Panel.Items.Count -eq 0) {
        $Panel.SelectedIndex = 0
        return
    }

    if ($Index -lt 0) {
        $Index = 0
    }
    if ($Index -ge $Panel.Items.Count) {
        $Index = $Panel.Items.Count - 1
    }
    $Panel.SelectedIndex = $Index

    if ($Panel.SelectedIndex -lt $Panel.TopIndex) {
        $Panel.TopIndex = $Panel.SelectedIndex
    }
    if ($VisibleRows -gt 0 -and $Panel.SelectedIndex -ge ($Panel.TopIndex + $VisibleRows)) {
        $Panel.TopIndex = [Math]::Max(0, $Panel.SelectedIndex - $VisibleRows + 1)
    }
}

function Get-ConsoleSizeSafe {
    $width = 80
    $height = 25

    try {
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
    }
    catch {
        try {
            $width = $Host.UI.RawUI.WindowSize.Width
            $height = $Host.UI.RawUI.WindowSize.Height
        }
        catch {
            $width = 80
            $height = 25
        }
    }

    if ($width -lt 40) { $width = 40 }
    if ($height -lt 12) { $height = 12 }

    return @{ Width = $width; Height = $height }
}

function Set-ConsoleColorsSafe {
    param(
        [ConsoleColor]$Foreground,
        [ConsoleColor]$Background
    )

    if (-not $script:Config.UseColor) {
        return
    }

    try {
        [Console]::ForegroundColor = $Foreground
        [Console]::BackgroundColor = $Background
    }
    catch {
    }
}

function Reset-ConsoleColorsSafe {
    try {
        if ($null -ne $script:OriginalForeground) {
            [Console]::ForegroundColor = $script:OriginalForeground
        }
        if ($null -ne $script:OriginalBackground) {
            [Console]::BackgroundColor = $script:OriginalBackground
        }
    }
    catch {
    }
}

function Write-At {
    param(
        [int]$Left,
        [int]$Top,
        [string]$Text,
        [int]$Width,
        [ConsoleColor]$Foreground = [ConsoleColor]::Gray,
        [ConsoleColor]$Background = [ConsoleColor]::Black
    )

    if ($Width -lt 0) {
        return
    }

    $output = Truncate-Text -Text $Text -Width $Width
    try {
        [Console]::SetCursorPosition($Left, $Top)
        Set-ConsoleColorsSafe -Foreground $Foreground -Background $Background
        [Console]::Write($output)
        Reset-ConsoleColorsSafe
    }
    catch {
        Write-Output $output
    }
}

function Clear-ScreenSafe {
    try {
        [Console]::Clear()
        $script:RenderState.LineCache = @{}
        $script:RenderState.FullRedrawRequired = $true
    }
    catch {
        Write-Output ''
    }
}

function Request-FullRedraw {
    $script:RenderState.FullRedrawRequired = $true
}

function New-RenderLine {
    param(
        [int]$Width
    )

    return @{
        Width = $Width
        Segments = New-Object System.Collections.ArrayList
    }
}

function Add-RenderSegment {
    param(
        [hashtable]$Line,
        [int]$Left,
        [string]$Text,
        [int]$Width,
        [ConsoleColor]$Foreground = [ConsoleColor]::Gray,
        [ConsoleColor]$Background = [ConsoleColor]::Black
    )

    if ($null -eq $Line -or $Width -le 0) {
        return
    }

    if ($Left -ge $Line.Width) {
        return
    }

    if ($Left -lt 0) {
        $trim = -1 * $Left
        if ($null -eq $Text) { $Text = '' }
        if ($Text.Length -le $trim) {
            return
        }
        $Text = $Text.Substring($trim)
        $Width = $Width - $trim
        $Left = 0
    }

    if (($Left + $Width) -gt $Line.Width) {
        $Width = $Line.Width - $Left
    }

    $segment = [pscustomobject]@{
        Left = $Left
        Order = $Line.Segments.Count
        Text = (Truncate-Text -Text $Text -Width $Width)
        Width = $Width
        Foreground = $Foreground
        Background = $Background
    }
    [void]$Line.Segments.Add($segment)
}

function Get-RenderLineKey {
    param(
        [hashtable]$Line
    )

    $parts = New-Object System.Collections.ArrayList
    $segments = @($Line.Segments | Sort-Object -Property Left, Order)
    foreach ($segment in $segments) {
        [void]$parts.Add(('{0}|{1}|{2}|{3}|{4}' -f $segment.Left, $segment.Order, [int]$segment.Foreground, [int]$segment.Background, $segment.Text))
    }
    return [string]::Join(([char]31), [string[]]$parts.ToArray([string]))
}

function Write-RenderLine {
    param(
        [int]$Top,
        [hashtable]$Line
    )

    Write-At -Left 0 -Top $Top -Text '' -Width $Line.Width -Foreground ([ConsoleColor]::Gray) -Background ([ConsoleColor]::Black)
    $segments = @($Line.Segments | Sort-Object -Property Left, Order)
    foreach ($segment in $segments) {
        Write-At -Left $segment.Left -Top $Top -Text $segment.Text -Width $segment.Width -Foreground $segment.Foreground -Background $segment.Background
    }
}

function Convert-RenderLineToPlainText {
    param(
        [hashtable]$Line
    )

    if ($null -eq $Line) {
        return ''
    }

    $chars = New-Object char[] $Line.Width
    for ($i = 0; $i -lt $Line.Width; $i++) {
        $chars[$i] = ' '
    }

    $segments = @($Line.Segments | Sort-Object -Property Left, Order)
    foreach ($segment in $segments) {
        $text = [string]$segment.Text
        for ($i = 0; $i -lt $text.Length -and ($segment.Left + $i) -lt $Line.Width; $i++) {
            if (($segment.Left + $i) -ge 0) {
                $chars[$segment.Left + $i] = $text[$i]
            }
        }
    }
    return (-join $chars)
}

function Convert-CharArrayToString {
    param(
        [char[]]$Characters
    )

    if ($null -eq $Characters -or $Characters.Length -eq 0) {
        return ''
    }
    return (-join $Characters)
}

function Test-UnicodeBoxDrawingSupported {
    if ($Ascii.IsPresent) {
        return $false
    }
    try {
        $codePage = [Console]::OutputEncoding.CodePage
        if ($codePage -eq 65001) {
            return $true
        }
        if (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) {
            return $true
        }
    }
    catch {
    }
    return $false
}

function New-BorderTheme {
    param(
        [string]$Style
    )

    if ($Style -eq 'Unicode' -and (Test-UnicodeBoxDrawingSupported)) {
        return @{
            Name = 'Unicode'
            TopLeft = [string][char]0x250C
            TopRight = [string][char]0x2510
            BottomLeft = [string][char]0x2514
            BottomRight = [string][char]0x2518
            Horizontal = [string][char]0x2500
            Vertical = [string][char]0x2502
            TDown = [string][char]0x252C
            TUp = [string][char]0x2534
            TLeft = [string][char]0x2524
            TRight = [string][char]0x251C
            Cross = [string][char]0x253C
        }
    }

    return @{
        Name = 'ASCII'
        TopLeft = '+'
        TopRight = '+'
        BottomLeft = '+'
        BottomRight = '+'
        Horizontal = '-'
        Vertical = '|'
        TDown = '+'
        TUp = '+'
        TLeft = '+'
        TRight = '+'
        Cross = '+'
    }
}

function Initialize-UiTheme {
    $borderStyle = [string]$script:Config.BorderStyle
    if ([string]::IsNullOrWhiteSpace($borderStyle)) {
        $borderStyle = 'ASCII'
    }
    if ($Ascii.IsPresent -or [bool]$script:Config.UseAscii) {
        $borderStyle = 'ASCII'
    }

    $colorTheme = [string]$script:Config.ColorTheme
    if ([string]::IsNullOrWhiteSpace($colorTheme)) {
        $colorTheme = 'Classic blue'
    }

    $colors = @{
        MenuForeground = [ConsoleColor]::White
        MenuBackground = [ConsoleColor]::DarkBlue
        MenuActiveForeground = [ConsoleColor]::Black
        MenuActiveBackground = [ConsoleColor]::Cyan
        MenuSeparatorForeground = [ConsoleColor]::Gray
        MenuSeparatorBackground = [ConsoleColor]::DarkBlue
        PanelForeground = [ConsoleColor]::Gray
        PanelBackground = [ConsoleColor]::Black
        PanelDirectoryForeground = [ConsoleColor]::Yellow
        PanelMarkedForeground = [ConsoleColor]::Yellow
        PanelTitleActiveForeground = [ConsoleColor]::Black
        PanelTitleActiveBackground = [ConsoleColor]::Cyan
        PanelTitleInactiveForeground = [ConsoleColor]::Gray
        PanelTitleInactiveBackground = [ConsoleColor]::Black
        PanelActiveSelectionForeground = [ConsoleColor]::Black
        PanelActiveSelectionBackground = [ConsoleColor]::Cyan
        PanelInactiveSelectionForeground = [ConsoleColor]::White
        PanelInactiveSelectionBackground = [ConsoleColor]::DarkBlue
        PanelActiveBorder = [ConsoleColor]::Cyan
        PanelInactiveBorder = [ConsoleColor]::DarkCyan
        HeaderForeground = [ConsoleColor]::White
        HeaderBackground = [ConsoleColor]::DarkBlue
        StatusForeground = [ConsoleColor]::White
        StatusBackground = [ConsoleColor]::DarkBlue
        CommandForeground = [ConsoleColor]::White
        CommandBackground = [ConsoleColor]::DarkBlue
        KeyForeground = [ConsoleColor]::Black
        KeyBackground = [ConsoleColor]::Gray
        KeyLabelForeground = [ConsoleColor]::Yellow
        KeyLabelBackground = [ConsoleColor]::DarkBlue
    }

    if ($colorTheme -eq 'Monochrome') {
        $colors.MenuBackground = [ConsoleColor]::Black
        $colors.MenuActiveBackground = [ConsoleColor]::Gray
        $colors.MenuSeparatorBackground = [ConsoleColor]::Black
        $colors.PanelActiveBorder = [ConsoleColor]::White
        $colors.PanelInactiveBorder = [ConsoleColor]::Gray
        $colors.PanelTitleActiveForeground = [ConsoleColor]::Black
        $colors.PanelTitleActiveBackground = [ConsoleColor]::Gray
        $colors.PanelTitleInactiveForeground = [ConsoleColor]::Gray
        $colors.PanelTitleInactiveBackground = [ConsoleColor]::Black
        $colors.PanelActiveSelectionForeground = [ConsoleColor]::Black
        $colors.PanelActiveSelectionBackground = [ConsoleColor]::Gray
        $colors.PanelInactiveSelectionForeground = [ConsoleColor]::White
        $colors.PanelInactiveSelectionBackground = [ConsoleColor]::Black
        $colors.HeaderBackground = [ConsoleColor]::Black
        $colors.StatusBackground = [ConsoleColor]::Black
        $colors.CommandBackground = [ConsoleColor]::Black
        $colors.KeyBackground = [ConsoleColor]::Black
        $colors.KeyLabelBackground = [ConsoleColor]::Black
        $colors.KeyForeground = [ConsoleColor]::White
    }
    elseif ($colorTheme -eq 'High contrast') {
        $colors.MenuForeground = [ConsoleColor]::Black
        $colors.MenuBackground = [ConsoleColor]::White
        $colors.MenuActiveForeground = [ConsoleColor]::White
        $colors.MenuActiveBackground = [ConsoleColor]::DarkRed
        $colors.MenuSeparatorForeground = [ConsoleColor]::Black
        $colors.MenuSeparatorBackground = [ConsoleColor]::White
        $colors.PanelActiveBorder = [ConsoleColor]::White
        $colors.PanelInactiveBorder = [ConsoleColor]::Gray
        $colors.PanelTitleActiveForeground = [ConsoleColor]::White
        $colors.PanelTitleActiveBackground = [ConsoleColor]::DarkRed
        $colors.PanelTitleInactiveForeground = [ConsoleColor]::White
        $colors.PanelTitleInactiveBackground = [ConsoleColor]::Black
        $colors.PanelActiveSelectionForeground = [ConsoleColor]::Black
        $colors.PanelActiveSelectionBackground = [ConsoleColor]::White
        $colors.PanelInactiveSelectionForeground = [ConsoleColor]::White
        $colors.PanelInactiveSelectionBackground = [ConsoleColor]::DarkGray
        $colors.HeaderForeground = [ConsoleColor]::Black
        $colors.HeaderBackground = [ConsoleColor]::White
        $colors.StatusForeground = [ConsoleColor]::Black
        $colors.StatusBackground = [ConsoleColor]::White
        $colors.CommandForeground = [ConsoleColor]::Black
        $colors.CommandBackground = [ConsoleColor]::White
        $colors.KeyForeground = [ConsoleColor]::Black
        $colors.KeyBackground = [ConsoleColor]::White
        $colors.KeyLabelForeground = [ConsoleColor]::White
        $colors.KeyLabelBackground = [ConsoleColor]::DarkRed
    }

    $script:UiTheme = @{
        Border = (New-BorderTheme -Style $borderStyle)
        Colors = $colors
        BorderStyleRequested = $borderStyle
        ColorTheme = $colorTheme
    }
}

function Get-BorderCharacters {
    if ($null -eq $script:UiTheme) {
        Initialize-UiTheme
    }
    $border = $script:UiTheme.Border
    return @{
        Name = $border.Name
        Corner = $border.TopLeft
        TopLeft = $border.TopLeft
        TopRight = $border.TopRight
        BottomLeft = $border.BottomLeft
        BottomRight = $border.BottomRight
        Horizontal = $border.Horizontal
        Vertical = $border.Vertical
        TDown = $border.TDown
        TUp = $border.TUp
        TLeft = $border.TLeft
        TRight = $border.TRight
        Cross = $border.Cross
    }
}

function Get-ThemeColors {
    if ($null -eq $script:UiTheme) {
        Initialize-UiTheme
    }
    return $script:UiTheme.Colors
}

function Render-LineCache {
    param(
        [System.Collections.ArrayList]$Lines,
        [int]$Width,
        [int]$Height
    )

    $force = [bool]$script:RenderState.FullRedrawRequired
    if ($script:RenderState.LastWidth -ne $Width -or $script:RenderState.LastHeight -ne $Height) {
        $force = $true
        $script:RenderState.LineCache = @{}
        $script:RenderState.LastWidth = $Width
        $script:RenderState.LastHeight = $Height
    }

    try { [Console]::CursorVisible = $false } catch {}

    for ($row = 0; $row -lt $Height; $row++) {
        $line = $Lines[$row]
        $key = Get-RenderLineKey -Line $line
        if ($force -or -not $script:RenderState.LineCache.ContainsKey($row) -or $script:RenderState.LineCache[$row] -ne $key) {
            Write-RenderLine -Top $row -Line $line
            $script:RenderState.LineCache[$row] = $key
        }
    }

    $script:RenderState.FullRedrawRequired = $false
}

function Get-ConsoleCommanderLayout {
    param(
        [int]$Width,
        [int]$Height
    )

    $compactMode = [string]$script:Config.CompactMode
    $minimumHeight = 16
    $tooSmall = ($Width -lt 60 -or $Height -lt $minimumHeight)
    $functionKeyRow = [Math]::Max(0, $Height - 1)
    $commandLineRow = [Math]::Max(0, $Height - 2)
    $bottomBorderRow = [Math]::Max(0, $Height - 3)
    $statusRow = [Math]::Max(0, $Height - 4)
    $fileListStartRow = 4
    $fileListEndRow = [Math]::Max($fileListStartRow, $statusRow - 1)
    $usableFileListHeight = [Math]::Max(1, $fileListEndRow - $fileListStartRow + 1)
    $autoCompact = ($Height -lt 22 -or $Width -lt 90)
    $compact = $autoCompact
    if ($compactMode -eq 'On') { $compact = $true }
    if ($compactMode -eq 'Off') { $compact = $false }

    $middleColumn = [Math]::Max(20, [int][Math]::Floor($Width / 2))
    if ($middleColumn -gt ($Width - 21)) {
        $middleColumn = [Math]::Max(1, $Width - 21)
    }
    $leftPanel = [pscustomobject]@{
        Left = 0
        Top = 1
        Width = $middleColumn + 1
        Height = [Math]::Max(1, $bottomBorderRow)
        Right = $middleColumn
        Bottom = $bottomBorderRow
    }
    $rightPanel = [pscustomobject]@{
        Left = $middleColumn
        Top = 1
        Width = $Width - $middleColumn
        Height = [Math]::Max(1, $bottomBorderRow)
        Right = $Width - 1
        Bottom = $bottomBorderRow
    }

    return [pscustomobject]@{
        Width = $Width
        Height = $Height
        TopMenuRow = 0
        LeftPanel = $leftPanel
        RightPanel = $rightPanel
        MiddleSeparatorColumn = $middleColumn
        TopBorderRow = 1
        TitleRow = 2
        HeaderRow = 3
        FileListStartRow = $fileListStartRow
        FileListEndRow = $fileListEndRow
        StatusRow = $statusRow
        BottomBorderRow = $bottomBorderRow
        CommandLineRow = $commandLineRow
        FunctionKeyRow = $functionKeyRow
        UsableFileListHeight = $usableFileListHeight
        Compact = $compact
        TooSmall = $tooSmall
    }
}

function Add-MenuBarToLines {
    param(
        [System.Collections.ArrayList]$Lines,
        [object]$Layout
    )

    $width = $Layout.Width
    $line = $Lines[$Layout.TopMenuRow]
    $colors = Get-ThemeColors
    $menuFg = $colors.MenuForeground
    $menuBg = $colors.MenuBackground
    if (-not [bool]$script:Config.UseColor) {
        $menuFg = [ConsoleColor]::Gray
        $menuBg = [ConsoleColor]::Black
    }
    Add-RenderSegment -Line $line -Left 0 -Text '' -Width $width -Foreground $menuFg -Background $menuBg
    $menus = @('Left', 'File', 'Command', 'Options', 'Right')
    $script:RenderState.TopMenuZones = @()

    $menuLeft = 1
    $minimumSlotWidth = 6
    $minimumMenuRight = $menuLeft + ($menus.Count * $minimumSlotWidth) - 1
    $rightContentLeft = $width

    $inputFull = ' ' + (Get-InputStatusText) + ' '
    $inputShort = ' ' + (Get-ShortInputStatusText) + ' '
    $inputText = ''
    if ($inputFull.Length -le [Math]::Max(6, [int]($width / 3))) {
        $inputText = $inputFull
    }
    elseif ($inputShort.Length -le [Math]::Max(4, [int]($width / 4))) {
        $inputText = $inputShort
    }

    $inputLeft = $width
    if (-not [string]::IsNullOrWhiteSpace($inputText)) {
        $candidateLeft = $width - $inputText.Length
        if ($candidateLeft -gt ($minimumMenuRight + 1)) {
            $inputLeft = $candidateLeft
            $rightContentLeft = $inputLeft
            Add-RenderSegment -Line $line -Left $inputLeft -Text $inputText -Width $inputText.Length -Foreground $menuFg -Background $menuBg
        }
    }

    $ownerText = ''
    foreach ($candidate in (Get-OwnerTopBarTextCandidates)) {
        $candidateText = ' ' + $candidate + ' '
        $candidateLeft = $rightContentLeft - $candidateText.Length
        if ($candidateLeft -gt ($minimumMenuRight + 1)) {
            $ownerText = $candidateText
            $ownerLeft = $candidateLeft
            break
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ownerText)) {
        Add-RenderSegment -Line $line -Left $ownerLeft -Text $ownerText -Width $ownerText.Length -Foreground $menuFg -Background $menuBg
        $rightContentLeft = $ownerLeft
    }

    $menuRight = [Math]::Max($menuLeft, $rightContentLeft - 2)
    $menuAreaWidth = $menuRight - $menuLeft + 1
    $slotWidth = [int][Math]::Floor($menuAreaWidth / $menus.Count)
    if ($slotWidth -lt 6) {
        $slotWidth = 6
    }

    for ($i = 0; $i -lt $menus.Count; $i++) {
        $slotStart = $menuLeft + ($i * $slotWidth)
        $slotEnd = $slotStart + $slotWidth - 1
        if ($i -eq ($menus.Count - 1)) {
            $slotEnd = $menuRight
        }
        if ($slotStart -gt $menuRight) {
            break
        }
        if ($slotEnd -gt $menuRight) {
            $slotEnd = $menuRight
        }
        $slotLen = $slotEnd - $slotStart + 1
        if ($slotLen -lt 2) {
            continue
        }

        $isOpen = ($script:RenderState.OpenTopMenuIndex -eq $i)
        $label = ' ' + $menus[$i] + ' '
        $fg = $menuFg
        $bg = $menuBg
        if ($isOpen) {
            $fg = $colors.MenuActiveForeground
            $bg = $colors.MenuActiveBackground
            if (-not [bool]$script:Config.UseColor) {
                $label = '[' + $menus[$i] + ']'
                $fg = [ConsoleColor]::White
                $bg = [ConsoleColor]::Black
            }
        }
        Add-RenderSegment -Line $line -Left $slotStart -Text (Center-Text -Text $label -Width $slotLen) -Width $slotLen -Foreground $fg -Background $bg
        $script:RenderState.TopMenuZones += [pscustomobject]@{
            Name = $menus[$i]
            Index = $i
            Left = $slotStart
            Right = $slotEnd
            Top = 0
        }

    }
}

function Add-MainFrameToLines {
    param(
        [System.Collections.ArrayList]$Lines,
        [object]$Layout
    )

    $border = Get-BorderCharacters
    $colors = Get-ThemeColors
    $borderColor = $colors.PanelInactiveBorder
    if (-not [bool]$script:Config.UseColor) {
        $borderColor = [ConsoleColor]::Gray
    }

    $width = $Layout.Width
    $middle = $Layout.MiddleSeparatorColumn
    $top = $Layout.TopBorderRow
    $bottom = $Layout.BottomBorderRow

    $topText = $border.TopLeft + ($border.Horizontal * [Math]::Max(0, $middle - 1)) + $border.TDown + ($border.Horizontal * [Math]::Max(0, $width - $middle - 2)) + $border.TopRight
    $bottomText = $border.BottomLeft + ($border.Horizontal * [Math]::Max(0, $middle - 1)) + $border.TUp + ($border.Horizontal * [Math]::Max(0, $width - $middle - 2)) + $border.BottomRight
    Add-RenderSegment -Line $Lines[$top] -Left 0 -Text $topText -Width $width -Foreground $borderColor -Background ([ConsoleColor]::Black)
    Add-RenderSegment -Line $Lines[$bottom] -Left 0 -Text $bottomText -Width $width -Foreground $borderColor -Background ([ConsoleColor]::Black)

    for ($row = $top + 1; $row -lt $bottom; $row++) {
        Add-RenderSegment -Line $Lines[$row] -Left 0 -Text $border.Vertical -Width 1 -Foreground $borderColor -Background ([ConsoleColor]::Black)
        Add-RenderSegment -Line $Lines[$row] -Left $middle -Text $border.Vertical -Width 1 -Foreground $borderColor -Background ([ConsoleColor]::Black)
        Add-RenderSegment -Line $Lines[$row] -Left ($width - 1) -Text $border.Vertical -Width 1 -Foreground $borderColor -Background ([ConsoleColor]::Black)
    }
}

function Get-PanelColumnPlan {
    param(
        [int]$InnerWidth,
        [bool]$Compact
    )

    $showAttr = ($InnerWidth -ge 42 -and -not $Compact)
    $showModified = ($InnerWidth -ge 52 -and -not $Compact)
    $showType = ($InnerWidth -ge 46)
    $showSize = ($InnerWidth -ge 34)
    $fixed = 3
    if ($showType) { $fixed += 7 }
    if ($showSize) { $fixed += 11 }
    if ($showModified) { $fixed += 17 }
    if ($showAttr) { $fixed += 7 }
    $nameWidth = $InnerWidth - $fixed
    if ($nameWidth -lt 8) {
        $nameWidth = [Math]::Max(4, $InnerWidth - 3)
        $showType = $false
        $showSize = $false
        $showModified = $false
        $showAttr = $false
    }
    return @{
        ShowType = $showType
        ShowSize = $showSize
        ShowModified = $showModified
        ShowAttr = $showAttr
        NameWidth = $nameWidth
    }
}

function Format-PanelRowText {
    param(
        [string]$Markers,
        [string]$Name,
        [string]$Type,
        [string]$Size,
        [string]$Modified,
        [string]$Attr,
        [hashtable]$Plan
    )

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add($Markers)
    [void]$parts.Add((Truncate-Text -Text $Name -Width $Plan.NameWidth))
    if ($Plan.ShowType) { [void]$parts.Add(('{0,-6}' -f $Type)) }
    if ($Plan.ShowSize) { [void]$parts.Add(('{0,10}' -f $Size)) }
    if ($Plan.ShowModified) { [void]$parts.Add(('{0,-16}' -f $Modified)) }
    if ($Plan.ShowAttr) { [void]$parts.Add(('{0,-6}' -f $Attr)) }
    return [string]::Join(' ', [string[]]$parts.ToArray([string]))
}

function Add-PanelToLines {
    param(
        [System.Collections.ArrayList]$Lines,
        [hashtable]$Panel,
        [object]$Layout,
        [object]$Rect,
        [bool]$Active
    )

    $left = $Rect.Left + 1
    $right = $Rect.Right - 1
    $innerWidth = $right - $left + 1
    if ($innerWidth -lt 8) {
        return
    }

    $colors = Get-ThemeColors
    $borderColor = $colors.PanelInactiveBorder
    if ($Active) {
        $borderColor = $colors.PanelActiveBorder
    }
    if (-not [bool]$script:Config.UseColor) {
        $borderColor = [ConsoleColor]::Gray
    }

    $activeLabel = ''
    if ($Active -and -not [bool]$script:Config.UseColor) {
        $activeLabel = '[ACTIVE] '
    }
    # English: Show a compact filter badge in the panel title so hidden filters are visible.
    # Magyar: A panel cimben rovid szuro jelzes latszik, hogy aktiv szuro ne maradjon rejtve.
    $filterBadge = ''
    if (-not [string]::IsNullOrWhiteSpace($Panel.FilterPattern)) {
        if ($Panel.FilterRegex) {
            $filterBadge = ' [F:re]'
        }
        else {
            $filterBadge = (' [F:{0}]' -f $Panel.FilterPattern)
        }
    }
    $title = (' {0}{1}: {2}{3} ' -f $activeLabel, $Panel.Name, (Get-PathForDisplay -Path $Panel.Path), $filterBadge)
    $titleFg = $colors.PanelTitleInactiveForeground
    $titleBg = $colors.PanelTitleInactiveBackground
    if ($Active) {
        $titleFg = $colors.PanelTitleActiveForeground
        $titleBg = $colors.PanelTitleActiveBackground
    }
    if (-not [bool]$script:Config.UseColor) {
        $titleFg = [ConsoleColor]::Gray
        $titleBg = [ConsoleColor]::Black
    }
    Add-RenderSegment -Line $Lines[$Layout.TitleRow] -Left $left -Text $title -Width $innerWidth -Foreground $titleFg -Background $titleBg

    $visibleRows = $Layout.UsableFileListHeight

    if ($Panel.SelectedIndex -lt $Panel.TopIndex) {
        $Panel.TopIndex = $Panel.SelectedIndex
    }
    if ($Panel.SelectedIndex -ge ($Panel.TopIndex + $visibleRows)) {
        $Panel.TopIndex = [Math]::Max(0, $Panel.SelectedIndex - $visibleRows + 1)
    }

    $plan = Get-PanelColumnPlan -InnerWidth $innerWidth -Compact $Layout.Compact

    $headerText = Format-PanelRowText -Markers 'SM' -Name 'Name' -Type 'Type' -Size 'Size' -Modified 'Modified' -Attr 'Attr' -Plan $plan
    Add-RenderSegment -Line $Lines[$Layout.HeaderRow] -Left $left -Text $headerText -Width $innerWidth -Foreground $colors.HeaderForeground -Background $colors.HeaderBackground

    for ($i = 0; $i -lt $visibleRows; $i++) {
        $itemIndex = $Panel.TopIndex + $i
        $screenRow = $Layout.FileListStartRow + $i
        $lineText = ''
        $foreground = $colors.PanelForeground
        $background = $colors.PanelBackground

        if ($itemIndex -lt $Panel.Items.Count) {
            $item = $Panel.Items[$itemIndex]
            $markMarker = ' '
            if ((-not $item.IsParent) -and $Panel.Marks.ContainsKey($item.FullName)) {
                $markMarker = '*'
            }
            $selectMarker = ' '
            if ($itemIndex -eq $Panel.SelectedIndex) {
                if ($Active) {
                    $selectMarker = '>'
                }
                elseif (-not [bool]$script:Config.UseColor) {
                    $selectMarker = '-'
                }
            }
            $markers = $selectMarker + $markMarker

            $type = 'FILE'
            if ($item.IsParent) { $type = 'UP' }
            elseif ($item.IsDrive) { $type = 'DRIVE' }
            elseif ($item.IsDirectory) { $type = 'DIR' }
            elseif ($item.IsVirtual) { $type = 'VIRT' }

            $size = Format-FileSize -Length $item.Length -IsDirectory $item.IsDirectory
            $dateText = ''
            if ($item.LastWriteTime -gt ([datetime]::MinValue)) {
                $dateText = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            }
            $attrs = Get-ShortAttributes -Attributes $item.Attributes
            $nameText = $item.Name
            if ($item.IsParent) {
                $nameText = '..'
            }
            $lineText = Format-PanelRowText -Markers $markers -Name $nameText -Type $type -Size $size -Modified $dateText -Attr $attrs -Plan $plan

            if ($item.IsDirectory -or $item.IsDrive -or $item.IsParent) {
                $foreground = $colors.PanelDirectoryForeground
            }
            if ($markMarker -eq '*') {
                $foreground = $colors.PanelMarkedForeground
            }
            if ($itemIndex -eq $Panel.SelectedIndex -and $Active) {
                $foreground = $colors.PanelActiveSelectionForeground
                $background = $colors.PanelActiveSelectionBackground
            }
            elseif ($itemIndex -eq $Panel.SelectedIndex) {
                $foreground = $colors.PanelInactiveSelectionForeground
                $background = $colors.PanelInactiveSelectionBackground
            }
        }

        Add-RenderSegment -Line $Lines[$screenRow] -Left $left -Text $lineText -Width $innerWidth -Foreground $foreground -Background $background
    }

    $statusRow = $Layout.StatusRow
    $status = $Panel.Status
    if ([string]::IsNullOrWhiteSpace($status)) {
        $current = Get-CurrentItem -Panel $Panel
        $filterStatus = ''
        if (-not [string]::IsNullOrWhiteSpace($Panel.FilterPattern)) {
            $filterMode = 'wildcard'
            if ($Panel.FilterRegex) { $filterMode = 'regex' }
            $filterStatus = (' | filter {0}: {1}' -f $filterMode, $Panel.FilterPattern)
        }
        if ($null -ne $current) {
            $status = ('{0} | {1} items | {2}{3}' -f $current.Name, $Panel.Items.Count, $Panel.Provider, $filterStatus)
        }
        else {
            $status = ('0 items | {0}{1}' -f $Panel.Provider, $filterStatus)
        }
    }
    Add-RenderSegment -Line $Lines[$statusRow] -Left $left -Text $status -Width $innerWidth -Foreground $colors.StatusForeground -Background $colors.StatusBackground
}

function Get-ShortPromptPath {
    param(
        [string]$Path,
        [int]$MaxLength
    )

    $display = Get-PathForDisplay -Path $Path
    if ($display.Length -le $MaxLength) {
        return $display
    }
    if ($MaxLength -le 4) {
        return (Truncate-Text -Text $display -Width $MaxLength)
    }
    return '...' + $display.Substring($display.Length - ($MaxLength - 3))
}

function Add-CommandLineToLines {
    param(
        [System.Collections.ArrayList]$Lines,
        [object]$Layout
    )

    $colors = Get-ThemeColors
    $fg = $colors.CommandForeground
    $bg = $colors.CommandBackground
    if (-not [bool]$script:Config.UseColor) {
        $fg = [ConsoleColor]::Gray
        $bg = [ConsoleColor]::Black
    }
    $line = $Lines[$Layout.CommandLineRow]
    $label = 'Cmd: '
    $maxPrompt = [Math]::Max(8, $Layout.Width - $script:State.CommandLine.Length - $label.Length - 1)
    if ($maxPrompt -gt 42) { $maxPrompt = 42 }
    $prompt = (Get-ShortPromptPath -Path (Get-ActivePanel).Path -MaxLength $maxPrompt) + '>'
    $text = $label + $prompt + $script:State.CommandLine
    Add-RenderSegment -Line $line -Left 0 -Text $text -Width $Layout.Width -Foreground $fg -Background $bg
    $script:RenderState.CommandCursorLeft = [Math]::Min($Layout.Width - 1, $label.Length + $prompt.Length + $script:State.CommandLine.Length)
    $script:RenderState.CommandCursorTop = $Layout.CommandLineRow
}

function Add-FunctionKeyBarToLines {
    param(
        [System.Collections.ArrayList]$Lines,
        [object]$Layout
    )

    $colors = Get-ThemeColors
    $line = $Lines[$Layout.FunctionKeyRow]
    $items = @(
        @('F1', 'Help'), @('F2', 'User'), @('F3', 'View'), @('F4', 'Edit'), @('F5', 'Copy'),
        @('F6', 'Move'), @('F7', 'Mkdir'), @('F8', 'Delete'), @('F9', 'Menu'), @('F10', 'Quit')
    )
    if (-not [bool]$script:Config.UseColor) {
        $parts = @()
        foreach ($item in $items) {
            $parts += ('{0}:{1}' -f $item[0], $item[1])
        }
        $keys = [string]::Join(' | ', [string[]]$parts)
        Add-RenderSegment -Line $line -Left 0 -Text $keys -Width $Layout.Width -Foreground ([ConsoleColor]::Gray) -Background ([ConsoleColor]::Black)
        return
    }

    Add-RenderSegment -Line $line -Left 0 -Text '' -Width $Layout.Width -Foreground $colors.KeyForeground -Background $colors.KeyBackground
    $x = 0
    foreach ($item in $items) {
        $key = [string]$item[0]
        $label = [string]$item[1]
        $tokenText = (' {0} ' -f $key)
        $labelText = (' {0} ' -f $label)
        $segmentWidth = $tokenText.Length + $labelText.Length + 1
        if (($x + $segmentWidth) -gt $Layout.Width) {
            break
        }
        Add-RenderSegment -Line $line -Left $x -Text $tokenText -Width $tokenText.Length -Foreground $colors.KeyLabelForeground -Background $colors.KeyLabelBackground
        $x += $tokenText.Length
        Add-RenderSegment -Line $line -Left $x -Text $labelText -Width $labelText.Length -Foreground $colors.KeyForeground -Background $colors.KeyBackground
        $x += $labelText.Length
        Add-RenderSegment -Line $line -Left $x -Text ' ' -Width 1 -Foreground $colors.KeyForeground -Background $colors.KeyBackground
        $x++
    }
}

function Build-AppScreenLines {
    param(
        [int]$Width,
        [int]$Height
    )

    $lines = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Height; $i++) {
        [void]$lines.Add((New-RenderLine -Width $Width))
    }

    $layout = Get-ConsoleCommanderLayout -Width $Width -Height $Height
    $script:RenderState.LastLayout = $layout

    if ($layout.TooSmall) {
        Add-RenderSegment -Line $lines[0] -Left 0 -Text ' console_commander ' -Width $Width -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)
        $message = 'Console too small. Minimum usable size is 60x16.'
        $left = [Math]::Max(0, [int](($Width - $message.Length) / 2))
        $top = [Math]::Max(1, [int]($Height / 2))
        Add-RenderSegment -Line $lines[$top] -Left $left -Text $message -Width ([Math]::Min($Width, $message.Length)) -Foreground ([ConsoleColor]::Yellow) -Background ([ConsoleColor]::Black)
        return $lines
    }

    Add-MenuBarToLines -Lines $lines -Layout $layout
    Add-MainFrameToLines -Lines $lines -Layout $layout

    $script:RenderState.LeftPanelZone = [pscustomobject]@{ Panel = 'Left'; Left = $layout.LeftPanel.Left; Top = $layout.TopBorderRow; Width = $layout.LeftPanel.Width; Height = ($layout.BottomBorderRow - $layout.TopBorderRow + 1); RowTop = $layout.FileListStartRow; VisibleRows = $layout.UsableFileListHeight }
    $script:RenderState.RightPanelZone = [pscustomobject]@{ Panel = 'Right'; Left = $layout.RightPanel.Left; Top = $layout.TopBorderRow; Width = $layout.RightPanel.Width; Height = ($layout.BottomBorderRow - $layout.TopBorderRow + 1); RowTop = $layout.FileListStartRow; VisibleRows = $layout.UsableFileListHeight }

    Add-PanelToLines -Lines $lines -Panel $script:State.LeftPanel -Layout $layout -Rect $layout.LeftPanel -Active ($script:State.ActivePanel -eq 'Left')
    Add-PanelToLines -Lines $lines -Panel $script:State.RightPanel -Layout $layout -Rect $layout.RightPanel -Active ($script:State.ActivePanel -eq 'Right')

    Add-CommandLineToLines -Lines $lines -Layout $layout
    Add-FunctionKeyBarToLines -Lines $lines -Layout $layout

    return $lines
}

function Render-App {
    $size = Get-ConsoleSizeSafe
    $width = $size.Width
    $height = $size.Height
    $lines = Build-AppScreenLines -Width $width -Height $height
    Render-LineCache -Lines $lines -Width $width -Height $height
    try {
        if ($null -ne $script:RenderState.CommandCursorTop) {
            [Console]::CursorVisible = $true
            [Console]::SetCursorPosition([int]$script:RenderState.CommandCursorLeft, [int]$script:RenderState.CommandCursorTop)
        }
    }
    catch {
    }
}

function Restore-ScreenRows {
    param(
        [int]$Top,
        [int]$Bottom
    )

    $size = Get-ConsoleSizeSafe
    $width = $size.Width
    $height = $size.Height
    if ($Top -lt 0) { $Top = 0 }
    if ($Bottom -ge $height) { $Bottom = $height - 1 }
    if ($Bottom -lt $Top) { return }

    $lines = Build-AppScreenLines -Width $width -Height $height
    for ($row = $Top; $row -le $Bottom; $row++) {
        Write-RenderLine -Top $row -Line $lines[$row]
        $script:RenderState.LineCache[$row] = Get-RenderLineKey -Line $lines[$row]
    }
}

function Get-ConsoleHostKind {
    $hostName = [string]$Host.Name
    $wtSession = -not [string]::IsNullOrWhiteSpace($env:WT_SESSION)
    $termProgram = [string]$env:TERM_PROGRAM
    $conEmuAnsi = [string]$env:ConEmuANSI
    if ($wtSession) {
        return 'WindowsTerminal'
    }
    if ($conEmuAnsi -match '(?i)ON') {
        return 'ConPTY'
    }
    if ($termProgram -match '(?i)Windows_Terminal|vscode|wezterm|mintty|alacritty') {
        return 'ConPTY'
    }
    if ($hostName -match '(?i)Visual Studio Code|Terminal') {
        return 'ConPTY'
    }
    if ($hostName -eq 'ConsoleHost') {
        return 'ClassicConhost'
    }
    return 'Unknown'
}

function New-MouseDiagnostics {
    $hostKind = Get-ConsoleHostKind
    $rawUiType = ''
    try {
        $rawUiType = [string]$Host.UI.RawUI.GetType().FullName
    }
    catch {
        $rawUiType = ''
    }

    return [ordered]@{
        Host = [string]$Host.Name
        HostName = [string]$Host.Name
        HostKind = $hostKind
        WTSessionPresent = (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION))
        TERM_PROGRAM = [string]$env:TERM_PROGRAM
        ConEmuANSI = [string]$env:ConEmuANSI
        RawUIType = $rawUiType
        StdInHandleValid = $false
        GetConsoleModeSucceeded = $false
        OriginalInputMode = ''
        RequestedWin32InputMode = ''
        EffectiveWin32InputMode = ''
        SetConsoleModeSucceeded = $false
        LastWin32Error = 0
        QuickEditWasEnabled = $false
        Win32MouseAvailable = $false
        VtInputAvailable = $false
        VtMouseBackendAvailable = $false
        SelectedBackend = 'KeyboardOnly'
        FailureReason = ''
    }
}

function Set-MouseFailureReason {
    param(
        [string]$Reason
    )

    if ($null -eq $script:MouseDiagnosticsState) {
        $script:MouseDiagnosticsState = New-MouseDiagnostics
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION) -and $Reason -match 'GetConsoleMode|SetConsoleMode|ReadConsoleInput|stdin|handle') {
        $Reason = 'Win32 console mouse events not exposed by this host. VT backend is recommended on Windows Terminal.'
    }
    $script:MouseDiagnosticsState.FailureReason = $Reason
    $script:MouseUnavailableReason = $Reason
}

function Get-InputStatusText {
    if ($script:MouseInputAvailable) {
        if ($script:MouseBackend -eq 'VT') {
            return 'Input: KB+Mouse VT'
        }
        if ($script:MouseBackend -eq 'Win32') {
            return 'Input: KB+Mouse Win32'
        }
        return 'Input: KB+Mouse'
    }

    if ($script:InputModePreference -eq 'Disabled') {
        return 'Input: Keyboard only - VT off'
    }
    if ($script:MouseBackendRequested -eq 'Win32') {
        return 'Input: Keyboard only - Win32 unavailable'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:MouseUnavailableReason) -and $script:MouseUnavailableReason -match 'QuickEdit|host') {
        return 'Input: Keyboard only - QuickEdit/host issue'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:MouseUnavailableReason)) {
        return 'Input: Keyboard only - Win32 unavailable'
    }
    return 'Input: Keyboard only'
}

function Get-ShortInputStatusText {
    if ($script:MouseInputAvailable) {
        if ($script:MouseBackend -eq 'VT') { return 'KB+VT' }
        if ($script:MouseBackend -eq 'Win32') { return 'KB+W32' }
        return 'KB+M'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:MouseUnavailableReason)) {
        return 'KB!'
    }
    return 'KB'
}

function Show-InputModeStatus {
    $details = @(
        (Get-InputStatusText),
        ('Requested backend: {0}' -f $script:MouseBackendRequested),
        ('Selected backend: {0}' -f $script:MouseBackend),
        ('Host kind: {0}' -f $script:HostKind),
        '',
        'Keyboard input is always available.'
    )
    if (-not [string]::IsNullOrWhiteSpace($script:MouseUnavailableReason)) {
        $details += ('Reason: {0}' -f $script:MouseUnavailableReason)
    }
    Show-TextViewer -Lines $details -Title 'Input mode'
}

function Get-MouseDiagnosticsLines {
    if ($null -eq $script:MouseDiagnosticsState) {
        $script:MouseDiagnosticsState = New-MouseDiagnostics
    }
    $lines = @(
        'Mouse diagnostics',
        '',
        ('Host kind: {0}' -f $script:MouseDiagnosticsState.HostKind),
        ('Host name: {0}' -f $script:MouseDiagnosticsState.HostName),
        ('WT_SESSION present: {0}' -f $script:MouseDiagnosticsState.WTSessionPresent),
        ('TERM_PROGRAM: {0}' -f $script:MouseDiagnosticsState.TERM_PROGRAM),
        ('ConEmuANSI: {0}' -f $script:MouseDiagnosticsState.ConEmuANSI),
        ('RawUI type: {0}' -f $script:MouseDiagnosticsState.RawUIType),
        '',
        ('Original input mode: {0}' -f $script:MouseDiagnosticsState.OriginalInputMode),
        ('Requested Win32 input mode: {0}' -f $script:MouseDiagnosticsState.RequestedWin32InputMode),
        ('Effective Win32 input mode: {0}' -f $script:MouseDiagnosticsState.EffectiveWin32InputMode),
        ('QuickEdit original state: {0}' -f $script:MouseDiagnosticsState.QuickEditWasEnabled),
        ('Win32 mouse available: {0}' -f $script:MouseDiagnosticsState.Win32MouseAvailable),
        ('VT input available: {0}' -f $script:MouseDiagnosticsState.VtInputAvailable),
        ('VT mouse backend available: {0}' -f $script:MouseDiagnosticsState.VtMouseBackendAvailable),
        ('Selected backend: {0}' -f $script:MouseDiagnosticsState.SelectedBackend),
        ('Failure reason: {0}' -f $script:MouseDiagnosticsState.FailureReason),
        ('Last Win32 error: {0}' -f $script:MouseDiagnosticsState.LastWin32Error)
    )
    return $lines
}

function Show-MouseDiagnosticsViewer {
    Show-TextViewer -Lines (Get-MouseDiagnosticsLines) -Title 'Mouse diagnostics'
}

function Ensure-NativeInputTypeLoaded {
    if ($null -ne ('ConsoleCommanderNativeInput' -as [type])) {
        return
    }

    $source = @"
using System;
using System.Runtime.InteropServices;

public class ConsoleCommanderNativeInput
{
    public const int STD_INPUT_HANDLE = -10;
    public const short KEY_EVENT = 0x0001;
    public const short MOUSE_EVENT = 0x0002;
    public const short WINDOW_BUFFER_SIZE_EVENT = 0x0004;
    public const uint ENABLE_MOUSE_INPUT = 0x0010;
    public const uint ENABLE_WINDOW_INPUT = 0x0008;
    public const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    public const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    public const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSE_EVENT_RECORD
    {
        public COORD dwMousePosition;
        public uint dwButtonState;
        public uint dwControlKeyState;
        public uint dwEventFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOW_BUFFER_SIZE_RECORD
    {
        public COORD dwSize;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD
    {
        [FieldOffset(0)]
        public short EventType;
        [FieldOffset(4)]
        public KEY_EVENT_RECORD KeyEvent;
        [FieldOffset(4)]
        public MOUSE_EVENT_RECORD MouseEvent;
        [FieldOffset(4)]
        public WINDOW_BUFFER_SIZE_RECORD WindowBufferSizeEvent;
    }

    public class InputEvent
    {
        public string Type;
        public bool KeyDown;
        public ushort VirtualKeyCode;
        public char KeyChar;
        public uint ControlKeyState;
        public short X;
        public short Y;
        public uint ButtonState;
        public uint EventFlags;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    [DllImport("kernel32.dll", EntryPoint="ReadConsoleInputW", SetLastError = true)]
    public static extern bool ReadConsoleInputW(IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

    public static InputEvent ReadInputEvent(IntPtr handle)
    {
        INPUT_RECORD[] records = new INPUT_RECORD[1];
        uint read = 0;
        while (true)
        {
            if (!ReadConsoleInputW(handle, records, 1, out read) || read == 0)
            {
                InputEvent failed = new InputEvent();
                failed.Type = "None";
                return failed;
            }
            INPUT_RECORD record = records[0];
            if (record.EventType == KEY_EVENT)
            {
                if (!record.KeyEvent.bKeyDown)
                {
                    continue;
                }
                InputEvent e = new InputEvent();
                e.Type = "Key";
                e.KeyDown = record.KeyEvent.bKeyDown;
                e.VirtualKeyCode = record.KeyEvent.wVirtualKeyCode;
                e.KeyChar = record.KeyEvent.UnicodeChar;
                e.ControlKeyState = record.KeyEvent.dwControlKeyState;
                return e;
            }
            if (record.EventType == MOUSE_EVENT)
            {
                InputEvent e = new InputEvent();
                e.Type = "Mouse";
                e.X = record.MouseEvent.dwMousePosition.X;
                e.Y = record.MouseEvent.dwMousePosition.Y;
                e.ButtonState = record.MouseEvent.dwButtonState;
                e.ControlKeyState = record.MouseEvent.dwControlKeyState;
                e.EventFlags = record.MouseEvent.dwEventFlags;
                return e;
            }
            if (record.EventType == WINDOW_BUFFER_SIZE_EVENT)
            {
                InputEvent e = new InputEvent();
                e.Type = "Resize";
                return e;
            }
        }
    }
}
"@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

function Get-ConsoleInputHandleAndMode {
    Ensure-NativeInputTypeLoaded
    $handle = [ConsoleCommanderNativeInput]::GetStdHandle([ConsoleCommanderNativeInput]::STD_INPUT_HANDLE)
    if ($handle -eq [IntPtr]::Zero -or $handle -eq ([IntPtr](-1))) {
        $script:MouseDiagnosticsState.LastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw 'stdin handle is not available'
    }
    $script:MouseDiagnosticsState.StdInHandleValid = $true

    [uint32]$mode = 0
    if (-not [ConsoleCommanderNativeInput]::GetConsoleMode($handle, [ref]$mode)) {
        $script:MouseDiagnosticsState.LastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw 'GetConsoleMode failed'
    }
    $script:MouseDiagnosticsState.GetConsoleModeSucceeded = $true
    if ([string]::IsNullOrWhiteSpace($script:MouseDiagnosticsState.OriginalInputMode)) {
        $script:MouseDiagnosticsState.OriginalInputMode = ('0x{0:X8}' -f $mode)
    }
    if ($null -eq $script:OriginalConsoleMode) {
        $script:OriginalConsoleMode = $mode
    }
    $script:ConsoleInputHandle = $handle
    return @{ Handle = $handle; Mode = $mode }
}

function Try-InitializeWin32MouseBackend {
    try {
        $consoleInfo = Get-ConsoleInputHandleAndMode
        $mode = [uint32]$consoleInfo.Mode
        $script:MouseDiagnosticsState.QuickEditWasEnabled = (($mode -band [ConsoleCommanderNativeInput]::ENABLE_QUICK_EDIT_MODE) -ne 0)
        [uint32]$newMode = ($mode -bor [ConsoleCommanderNativeInput]::ENABLE_MOUSE_INPUT -bor [ConsoleCommanderNativeInput]::ENABLE_WINDOW_INPUT -bor [ConsoleCommanderNativeInput]::ENABLE_EXTENDED_FLAGS)
        $newMode = [uint32]($newMode -band [uint32]0xffffffbf)
        $script:MouseDiagnosticsState.RequestedWin32InputMode = ('0x{0:X8}' -f $newMode)
        if (-not [ConsoleCommanderNativeInput]::SetConsoleMode($consoleInfo.Handle, $newMode)) {
            $script:MouseDiagnosticsState.LastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw 'SetConsoleMode failed for Win32 mouse mode'
        }
        $script:MouseDiagnosticsState.SetConsoleModeSucceeded = $true
        [uint32]$effectiveMode = 0
        if ([ConsoleCommanderNativeInput]::GetConsoleMode($consoleInfo.Handle, [ref]$effectiveMode)) {
            $script:MouseDiagnosticsState.EffectiveWin32InputMode = ('0x{0:X8}' -f $effectiveMode)
            $script:MouseDiagnosticsState.Win32MouseAvailable = (($effectiveMode -band [ConsoleCommanderNativeInput]::ENABLE_MOUSE_INPUT) -ne 0)
        }
        else {
            $script:MouseDiagnosticsState.Win32MouseAvailable = $true
        }
        $script:MouseInputAvailable = $true
        $script:MouseBackend = 'Win32'
        $script:MouseDiagnosticsState.SelectedBackend = 'Win32'
        $script:MouseDiagnosticsState.FailureReason = ''
        return $true
    }
    catch {
        $script:MouseDiagnosticsState.Win32MouseAvailable = $false
        $script:MouseDiagnosticsState.LastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Set-MouseFailureReason -Reason $_.Exception.Message
        return $false
    }
}

function Enable-VtMouseSequences {
    $esc = [string][char]27
    [Console]::Write($esc + '[?1000h')
    [Console]::Write($esc + '[?1002h')
    [Console]::Write($esc + '[?1006h')
    $script:VtMouseEnabled = $true
}

function Disable-VtMouseSequences {
    if (-not $script:VtMouseEnabled) {
        return
    }
    try {
        $esc = [string][char]27
        [Console]::Write($esc + '[?1006l')
        [Console]::Write($esc + '[?1002l')
        [Console]::Write($esc + '[?1000l')
    }
    catch {
    }
    $script:VtMouseEnabled = $false
}

function Try-InitializeVtMouseBackend {
    try {
        $consoleInfo = Get-ConsoleInputHandleAndMode
        $mode = [uint32]$consoleInfo.Mode
        [uint32]$vtMode = ($mode -bor [ConsoleCommanderNativeInput]::ENABLE_VIRTUAL_TERMINAL_INPUT -bor [ConsoleCommanderNativeInput]::ENABLE_WINDOW_INPUT -bor [ConsoleCommanderNativeInput]::ENABLE_EXTENDED_FLAGS)
        if (-not [ConsoleCommanderNativeInput]::SetConsoleMode($consoleInfo.Handle, $vtMode)) {
            $script:MouseDiagnosticsState.LastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw 'SetConsoleMode failed for VT input mode'
        }
        $script:MouseDiagnosticsState.VtInputAvailable = $true
        Enable-VtMouseSequences
        $script:MouseDiagnosticsState.VtMouseBackendAvailable = $true
        $script:MouseInputAvailable = $true
        $script:MouseBackend = 'VT'
        $script:MouseDiagnosticsState.SelectedBackend = 'VT'
        $script:MouseDiagnosticsState.FailureReason = ''
        return $true
    }
    catch {
        $script:MouseDiagnosticsState.VtMouseBackendAvailable = $false
        if (-not [string]::IsNullOrWhiteSpace($script:MouseDiagnosticsState.FailureReason)) {
            Set-MouseFailureReason -Reason ('VT backend unavailable: {0}' -f $_.Exception.Message)
        }
        else {
            Set-MouseFailureReason -Reason $_.Exception.Message
        }
        return $false
    }
}

function Initialize-ConsoleInputMode {
    $script:MouseInputAvailable = $false
    $script:MouseUnavailableReason = ''
    $script:MouseBackend = 'KeyboardOnly'
    $script:MouseDiagnosticsState = New-MouseDiagnostics
    $script:HostKind = $script:MouseDiagnosticsState.HostKind
    $script:PendingInputEvents.Clear()
    $script:MouseBackendRequested = [string]$script:Config.MouseMode
    if ([string]::IsNullOrWhiteSpace($script:MouseBackendRequested)) {
        $script:MouseBackendRequested = 'Auto'
    }
    $script:InputModePreference = $script:MouseBackendRequested

    if ($script:InputModePreference -eq 'Disabled') {
        Set-MouseFailureReason -Reason 'Mouse input disabled by user preference.'
        $script:MouseDiagnosticsState.SelectedBackend = 'KeyboardOnly'
        Write-AppLog -Level 'INFO' -Message 'Mouse input disabled by user preference; keyboard input remains active.'
        Request-FullRedraw
        return
    }

    $attempts = @()
    if ($script:MouseBackendRequested -eq 'Win32') {
        $attempts = @('Win32')
    }
    elseif ($script:MouseBackendRequested -eq 'VT') {
        $attempts = @('VT')
    }
    else {
        if ($script:HostKind -eq 'WindowsTerminal' -or $script:HostKind -eq 'ConPTY') {
            $attempts = @('VT', 'Win32')
        }
        else {
            $attempts = @('Win32', 'VT')
        }
    }

    $selected = $false
    foreach ($attempt in $attempts) {
        if ($attempt -eq 'Win32') {
            $selected = Try-InitializeWin32MouseBackend
        }
        elseif ($attempt -eq 'VT') {
            $selected = Try-InitializeVtMouseBackend
        }
        if ($selected) {
            break
        }
    }

    if (-not $selected) {
        $script:MouseInputAvailable = $false
        $script:MouseBackend = 'KeyboardOnly'
        $script:MouseDiagnosticsState.SelectedBackend = 'KeyboardOnly'
        if ([string]::IsNullOrWhiteSpace($script:MouseDiagnosticsState.FailureReason)) {
            Set-MouseFailureReason -Reason 'Mouse backend unavailable for this host.'
        }
        Write-AppLog -Level 'WARN' -Message ('Mouse input unavailable; keyboard-only mode active: {0}' -f $script:MouseUnavailableReason)
    }
    else {
        Write-AppLog -Level 'INFO' -Message ('Mouse backend active: {0}' -f $script:MouseBackend)
    }
    Write-AppLog -Level 'INFO' -Message ('Mouse diagnostics: {0}' -f ([string]::Join('; ', [string[]](Get-MouseDiagnosticsLines))))
    Request-FullRedraw
}

function Restore-ConsoleInputMode {
    try {
        Disable-VtMouseSequences
        if ($script:ConsoleInputHandle -ne [IntPtr]::Zero -and $null -ne $script:OriginalConsoleMode) {
            [void][ConsoleCommanderNativeInput]::SetConsoleMode($script:ConsoleInputHandle, [uint32]$script:OriginalConsoleMode)
        }
        $script:MouseInputAvailable = $false
        $script:MouseBackend = 'KeyboardOnly'
        $script:PendingInputEvents.Clear()
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ('Console input mode restore failed: {0}' -f $_.Exception.Message)
    }
}

function Set-MouseBackendPreference {
    param(
        [string]$Mode
    )

    if (@('Auto', 'Win32', 'VT', 'Disabled') -notcontains $Mode) {
        $Mode = 'Auto'
    }
    Restore-ConsoleInputMode
    $script:Config.MouseMode = $Mode
    $script:InputModePreference = $Mode
    $script:MouseBackendRequested = $Mode
    Initialize-ConsoleInputMode
    Show-Message -Message (Get-InputStatusText)
}

function Enable-MouseInputMode {
    Set-MouseBackendPreference -Mode 'Auto'
}

function Disable-MouseInputMode {
    Set-MouseBackendPreference -Mode 'Disabled'
}

function Retry-MouseInputMode {
    Restore-ConsoleInputMode
    Initialize-ConsoleInputMode
    Show-Message -Message (Get-InputStatusText)
}

function Read-KeySafe {
    try {
        return [Console]::ReadKey($true)
    }
    catch {
        throw 'Console keyboard input is not available.'
    }
}

function Read-KeyWithTimeout {
    param(
        [int]$TimeoutMs = 20
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            if ([Console]::KeyAvailable) {
                return [Console]::ReadKey($true)
            }
        }
        catch {
            return $null
        }
        Start-Sleep -Milliseconds 5
    }
    return $null
}

function New-InputKeyEvent {
    param(
        [ConsoleKeyInfo]$KeyInfo
    )

    if ($null -ne $KeyInfo) {
        $KeyInfo = Normalize-ConsoleKeyInfo -KeyInfo $KeyInfo
    }

    return [pscustomobject]@{
        Type = 'Key'
        KeyInfo = $KeyInfo
        X = 0
        Y = 0
        ButtonState = 0
        ButtonDown = $false
        ButtonUp = $false
        Click = $false
        DoubleClick = $false
        NativeDoubleClick = $false
        SyntheticDoubleClick = $false
        WheelDelta = 0
        EventFlags = 0
        Backend = $script:MouseBackend
        ClickSequence = 0
        ZoneKind = $null
        PanelName = $null
        RowIndex = $null
        SuppressedDuplicateClick = $false
        ClickElapsedMs = -1
        ActionTaken = 'Ignored'
    }
}

function New-InputMouseEvent {
    param(
        [int]$X,
        [int]$Y,
        [uint32]$ButtonState = 0,
        [bool]$ButtonDown = $false,
        [bool]$ButtonUp = $false,
        [bool]$Click = $false,
        [bool]$DoubleClick = $false,
        [int]$WheelDelta = 0,
        [uint32]$EventFlags = 0,
        [string]$Backend = $script:MouseBackend,
        [bool]$NativeDoubleClick = $false
    )

    return [pscustomobject]@{
        Type = 'Mouse'
        KeyInfo = $null
        X = $X
        Y = $Y
        ButtonState = $ButtonState
        ButtonDown = $ButtonDown
        ButtonUp = $ButtonUp
        Click = $Click
        DoubleClick = $DoubleClick
        NativeDoubleClick = $NativeDoubleClick
        SyntheticDoubleClick = $false
        WheelDelta = $WheelDelta
        EventFlags = $EventFlags
        Backend = $Backend
        ClickSequence = 0
        ZoneKind = $null
        PanelName = $null
        RowIndex = $null
        SuppressedDuplicateClick = $false
        ClickElapsedMs = -1
        ActionTaken = 'Ignored'
    }
}

function Add-PendingInputEvent {
    param(
        [object]$InputEvent
    )
    if ($null -ne $InputEvent) {
        [void]$script:PendingInputEvents.Enqueue($InputEvent)
    }
}

function Pop-PendingInputEvent {
    if ($script:PendingInputEvents.Count -gt 0) {
        return $script:PendingInputEvents.Dequeue()
    }
    return $null
}

function New-SafeConsoleKeyInfo {
    param(
        [char]$KeyChar,
        [System.ConsoleKey]$Key,
        [bool]$Shift = $false,
        [bool]$Alt = $false,
        [bool]$Control = $false
    )

    return New-Object -TypeName System.ConsoleKeyInfo -ArgumentList @(
        $KeyChar,
        ([System.ConsoleKey]$Key),
        [bool]$Shift,
        [bool]$Alt,
        [bool]$Control
    )
}

function Normalize-ConsoleKeyInfo {
    param(
        [System.ConsoleKeyInfo]$KeyInfo
    )

    if ($null -eq $KeyInfo) {
        return $null
    }

    $key = $KeyInfo.Key
    $char = $KeyInfo.KeyChar
    $shift = (($KeyInfo.Modifiers -band [System.ConsoleModifiers]::Shift) -ne 0)
    $alt = (($KeyInfo.Modifiers -band [System.ConsoleModifiers]::Alt) -ne 0)
    $control = (($KeyInfo.Modifiers -band [System.ConsoleModifiers]::Control) -ne 0)
    $code = [int][char]$char
    $keyValue = [int]$key

    if ($key -eq [System.ConsoleKey]::NoName -or $keyValue -eq 0) {
        if ($code -eq 13 -or $code -eq 10) {
            return New-SafeConsoleKeyInfo -KeyChar ([char]13) -Key ([System.ConsoleKey]::Enter) -Shift $shift -Alt $alt -Control $control
        }
        if ($code -eq 9) {
            return New-SafeConsoleKeyInfo -KeyChar ([char]9) -Key ([System.ConsoleKey]::Tab) -Shift $shift -Alt $alt -Control $control
        }
        if ($code -eq 8) {
            return New-SafeConsoleKeyInfo -KeyChar ([char]8) -Key ([System.ConsoleKey]::Backspace) -Shift $shift -Alt $alt -Control $control
        }
        if ($code -eq 27) {
            return New-SafeConsoleKeyInfo -KeyChar ([char]27) -Key ([System.ConsoleKey]::Escape) -Shift $shift -Alt $alt -Control $control
        }
    }

    if ($code -eq 13 -or $code -eq 10) {
        return New-SafeConsoleKeyInfo -KeyChar ([char]13) -Key ([System.ConsoleKey]::Enter) -Shift $shift -Alt $alt -Control $control
    }

    return $KeyInfo
}

function Convert-NativeKeyEvent {
    param(
        [object]$NativeEvent
    )

    $shift = (($NativeEvent.ControlKeyState -band 0x0010) -ne 0)
    $alt = ((($NativeEvent.ControlKeyState -band 0x0001) -ne 0) -or (($NativeEvent.ControlKeyState -band 0x0002) -ne 0))
    $control = ((($NativeEvent.ControlKeyState -band 0x0004) -ne 0) -or (($NativeEvent.ControlKeyState -band 0x0008) -ne 0))
    $keyChar = [char]$NativeEvent.KeyChar
    $key = Convert-VirtualKeyCodeToConsoleKey -VirtualKeyCode ([int]$NativeEvent.VirtualKeyCode) -KeyChar $keyChar
    return New-SafeConsoleKeyInfo -KeyChar $keyChar -Key $key -Shift $shift -Alt $alt -Control $control
}

function Convert-CharacterToConsoleKey {
    param(
        [char]$Character
    )

    $code = [int][char]$Character
    if ($code -eq 0) { return [ConsoleKey]::Spacebar }
    if ($code -eq 8) { return [ConsoleKey]::Backspace }
    if ($code -eq 9) { return [ConsoleKey]::Tab }
    if ($code -eq 10 -or $code -eq 13) { return [ConsoleKey]::Enter }
    if ($code -eq 27) { return [ConsoleKey]::Escape }
    if ($Character -eq ' ') { return [ConsoleKey]::Spacebar }

    $text = [string]$Character
    $upper = $text.ToUpperInvariant()
    if ($upper -ge 'A' -and $upper -le 'Z') {
        try { return [ConsoleKey]$upper } catch {}
    }
    if ($text -ge '0' -and $text -le '9') {
        try { return [ConsoleKey]('D{0}' -f $text) } catch {}
    }

    switch ($Character) {
        '+' { return [ConsoleKey]::Add }
        '-' { return [ConsoleKey]::OemMinus }
        '=' { return [ConsoleKey]::OemPlus }
        ',' { return [ConsoleKey]::OemComma }
        '.' { return [ConsoleKey]::OemPeriod }
        '/' { return [ConsoleKey]::OemQuestion }
        '\' { return [ConsoleKey]::Oem5 }
        ';' { return [ConsoleKey]::Oem1 }
        "'" { return [ConsoleKey]::Oem7 }
        '[' { return [ConsoleKey]::Oem4 }
        ']' { return [ConsoleKey]::Oem6 }
        '`' { return [ConsoleKey]::Oem3 }
    }

    return [ConsoleKey]::Spacebar
}

function Convert-VirtualKeyCodeToConsoleKey {
    param(
        [int]$VirtualKeyCode,
        [char]$KeyChar
    )

    try {
        if ($VirtualKeyCode -gt 0) {
            return [ConsoleKey]$VirtualKeyCode
        }
    }
    catch {
    }

    return (Convert-CharacterToConsoleKey -Character $KeyChar)
}

function New-ConsoleKeyInfoFromCharacter {
    param(
        [char]$Character,
        [bool]$Shift = $false,
        [bool]$Alt = $false,
        [bool]$Control = $false
    )

    $key = Convert-CharacterToConsoleKey -Character $Character
    return New-SafeConsoleKeyInfo -KeyChar $Character -Key $key -Shift $Shift -Alt $Alt -Control $Control
}

function Convert-VtModifierValue {
    param(
        [int]$ModifierValue
    )

    $shift = $false
    $alt = $false
    $control = $false
    if ($ModifierValue -gt 1) {
        $mask = $ModifierValue - 1
        $shift = (($mask -band 1) -ne 0)
        $alt = (($mask -band 2) -ne 0)
        $control = (($mask -band 4) -ne 0)
    }

    return @{
        Shift = $shift
        Alt = $alt
        Control = $control
    }
}

function New-VtConsoleKeyInfo {
    param(
        [System.ConsoleKey]$Key,
        [hashtable]$Modifiers = $null
    )

    $shift = $false
    $alt = $false
    $control = $false
    if ($null -ne $Modifiers) {
        $shift = [bool]$Modifiers.Shift
        $alt = [bool]$Modifiers.Alt
        $control = [bool]$Modifiers.Control
    }

    return New-SafeConsoleKeyInfo -KeyChar ([char]0) -Key $Key -Shift $shift -Alt $alt -Control $control
}

function Try-ConvertVtKeySequence {
    param(
        [string]$Sequence
    )

    if ([string]::IsNullOrEmpty($Sequence)) {
        return $null
    }

    $ss3Map = @{
        'OP' = [System.ConsoleKey]::F1
        'OQ' = [System.ConsoleKey]::F2
        'OR' = [System.ConsoleKey]::F3
        'OS' = [System.ConsoleKey]::F4
    }
    if ($ss3Map.ContainsKey($Sequence)) {
        return (New-VtConsoleKeyInfo -Key $ss3Map[$Sequence])
    }

    if ($Sequence -match '^\[(.*)([A-Za-z~])$') {
        $body = [string]$matches[1]
        $final = [string]$matches[2]
    }
    else {
        return $null
    }
    $modifiers = Convert-VtModifierValue -ModifierValue 1
    $parts = @()
    if (-not [string]::IsNullOrEmpty($body)) {
        $parts = @($body -split ';')
        if ($parts.Count -gt 1) {
            $modifierNumber = 1
            if ([int]::TryParse([string]$parts[$parts.Count - 1], [ref]$modifierNumber)) {
                $modifiers = Convert-VtModifierValue -ModifierValue $modifierNumber
            }
        }
    }

    switch ($final) {
        'A' { return (New-VtConsoleKeyInfo -Key ([System.ConsoleKey]::UpArrow) -Modifiers $modifiers) }
        'B' { return (New-VtConsoleKeyInfo -Key ([System.ConsoleKey]::DownArrow) -Modifiers $modifiers) }
        'C' { return (New-VtConsoleKeyInfo -Key ([System.ConsoleKey]::RightArrow) -Modifiers $modifiers) }
        'D' { return (New-VtConsoleKeyInfo -Key ([System.ConsoleKey]::LeftArrow) -Modifiers $modifiers) }
        'H' { return (New-VtConsoleKeyInfo -Key ([System.ConsoleKey]::Home) -Modifiers $modifiers) }
        'F' { return (New-VtConsoleKeyInfo -Key ([System.ConsoleKey]::End) -Modifiers $modifiers) }
        '~' {
            if ($parts.Count -eq 0) {
                return $null
            }
            $code = 0
            if (-not [int]::TryParse([string]$parts[0], [ref]$code)) {
                return $null
            }
            $tildeMap = @{
                1 = [System.ConsoleKey]::Home
                2 = [System.ConsoleKey]::Insert
                3 = [System.ConsoleKey]::Delete
                4 = [System.ConsoleKey]::End
                5 = [System.ConsoleKey]::PageUp
                6 = [System.ConsoleKey]::PageDown
                11 = [System.ConsoleKey]::F1
                12 = [System.ConsoleKey]::F2
                13 = [System.ConsoleKey]::F3
                14 = [System.ConsoleKey]::F4
                15 = [System.ConsoleKey]::F5
                17 = [System.ConsoleKey]::F6
                18 = [System.ConsoleKey]::F7
                19 = [System.ConsoleKey]::F8
                20 = [System.ConsoleKey]::F9
                21 = [System.ConsoleKey]::F10
                23 = [System.ConsoleKey]::F11
                24 = [System.ConsoleKey]::F12
            }
            if ($tildeMap.ContainsKey($code)) {
                return (New-VtConsoleKeyInfo -Key $tildeMap[$code] -Modifiers $modifiers)
            }
        }
    }

    return $null
}

function Try-ConvertVtMouseSequence {
    param(
        [string]$Sequence
    )

    if ($Sequence -match '^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$') {
        $buttonCode = [int]$matches[1]
        $x = [Math]::Max(0, [int]$matches[2] - 1)
        $y = [Math]::Max(0, [int]$matches[3] - 1)
        $suffix = [string]$matches[4]
    }
    else {
        return $null
    }
    $wheelDelta = 0
    if (($buttonCode -band 64) -ne 0) {
        if (($buttonCode -band 1) -eq 0) {
            $wheelDelta = 120
        }
        else {
            $wheelDelta = -120
        }
    }
    $motion = (($buttonCode -band 32) -ne 0)
    $buttonDown = ($suffix -ceq 'M' -and $wheelDelta -eq 0 -and -not $motion)
    $buttonUp = ($suffix -ceq 'm' -and $wheelDelta -eq 0)
    $click = $buttonDown
    $eventFlags = 0
    if ($motion) {
        $eventFlags = 1
    }

    return (New-InputMouseEvent -X $x -Y $y -ButtonState ([uint32]$buttonCode) -ButtonDown $buttonDown -ButtonUp $buttonUp -Click $click -DoubleClick $false -WheelDelta $wheelDelta -EventFlags ([uint32]$eventFlags) -Backend 'VT' -NativeDoubleClick $false)
}

function Try-ReadVtSequenceEvent {
    $chars = New-Object System.Collections.ArrayList
    $finalChars = @('A', 'B', 'C', 'D', 'H', 'F', 'P', 'Q', 'R', 'S', '~', 'M', 'm')
    for ($i = 0; $i -lt 48; $i++) {
        $next = Read-KeyWithTimeout -TimeoutMs 22
        if ($null -eq $next) {
            break
        }
        if ([int]$next.KeyChar -eq 0) {
            Add-PendingInputEvent -InputEvent (New-InputKeyEvent -KeyInfo $next)
            break
        }
        [void]$chars.Add([string]$next.KeyChar)
        if ($finalChars -contains ([string]$next.KeyChar)) {
            break
        }
    }

    if ($chars.Count -eq 0) {
        return $null
    }

    $sequence = [string]::Join('', [string[]]$chars.ToArray([string]))
    $vtMouse = Try-ConvertVtMouseSequence -Sequence $sequence
    if ($null -ne $vtMouse) {
        return $vtMouse
    }

    $vtKey = Try-ConvertVtKeySequence -Sequence $sequence
    if ($null -ne $vtKey) {
        return (New-InputKeyEvent -KeyInfo $vtKey)
    }

    foreach ($ch in $chars) {
        $charValue = [char]$ch
        $keyInfo = New-ConsoleKeyInfoFromCharacter -Character $charValue
        Add-PendingInputEvent -InputEvent (New-InputKeyEvent -KeyInfo $keyInfo)
    }
    return $null
}

function New-InputParserErrorEvent {
    return [pscustomobject]@{
        Type = 'InputError'
        KeyInfo = $null
        X = 0
        Y = 0
        ButtonState = 0
        ButtonDown = $false
        ButtonUp = $false
        Click = $false
        DoubleClick = $false
        NativeDoubleClick = $false
        SyntheticDoubleClick = $false
        WheelDelta = 0
        EventFlags = 0
        Backend = $script:MouseBackend
        ClickSequence = 0
        ZoneKind = $null
        PanelName = $null
        RowIndex = $null
        SuppressedDuplicateClick = $false
        ClickElapsedMs = -1
        ActionTaken = 'Ignored'
    }
}

function Disable-VtInputAfterParserFailure {
    param(
        [string]$Reason
    )

    try {
        Disable-VtMouseSequences
    }
    catch {
    }
    $script:MouseInputAvailable = $false
    $script:MouseBackend = 'KeyboardOnly'
    Set-MouseFailureReason -Reason $Reason
    Write-AppLog -Level 'ERROR' -Message ('VT input parser failed; keyboard-only fallback active: {0}' -f $Reason)
    Request-FullRedraw
}

function Read-VtInputEvent {
    try {
        $queued = Pop-PendingInputEvent
        if ($null -ne $queued) {
            return $queued
        }

        $key = Read-KeySafe
        $isEscape = ($key.Key -eq [ConsoleKey]::Escape -or [int][char]$key.KeyChar -eq 27)
        if ($isEscape) {
            $sequenceEvent = Try-ReadVtSequenceEvent
            if ($null -ne $sequenceEvent) {
                return $sequenceEvent
            }
        }
        return (New-InputKeyEvent -KeyInfo $key)
    }
    catch {
        Disable-VtInputAfterParserFailure -Reason $_.Exception.Message
        return (New-InputParserErrorEvent)
    }
}

function Read-InputEvent {
    $queued = Pop-PendingInputEvent
    if ($null -ne $queued) {
        return $queued
    }

    if ($script:MouseInputAvailable -and $script:MouseBackend -eq 'Win32') {
        while ($true) {
            try {
                $nativeEvent = [ConsoleCommanderNativeInput]::ReadInputEvent($script:ConsoleInputHandle)
                if ($null -eq $nativeEvent -or $nativeEvent.Type -eq 'None') {
                    continue
                }
                if ($nativeEvent.Type -eq 'Resize') {
                    Request-FullRedraw
                    return [pscustomobject]@{ Type = 'Resize'; KeyInfo = $null; X = 0; Y = 0; ButtonState = 0; ButtonDown = $false; ButtonUp = $false; Click = $false; DoubleClick = $false; NativeDoubleClick = $false; SyntheticDoubleClick = $false; WheelDelta = 0; EventFlags = 0; Backend = 'Win32'; ClickSequence = 0; ZoneKind = $null; PanelName = $null; RowIndex = $null; SuppressedDuplicateClick = $false; ClickElapsedMs = -1; ActionTaken = 'Ignored' }
                }
                if ($nativeEvent.Type -eq 'Key') {
                    return (New-InputKeyEvent -KeyInfo (Convert-NativeKeyEvent -NativeEvent $nativeEvent))
                }
                if ($nativeEvent.Type -eq 'Mouse') {
                    $nativeDoubleClick = ($nativeEvent.EventFlags -eq 0x0002)
                    $wheelDelta = 0
                    if ($nativeEvent.EventFlags -eq 0x0004 -or $nativeEvent.EventFlags -eq 0x0008) {
                        $wheelWord = [int](($nativeEvent.ButtonState -shr 16) -band 0xffff)
                        if ($wheelWord -gt 32767) {
                            $wheelDelta = $wheelWord - 65536
                        }
                        else {
                            $wheelDelta = $wheelWord
                        }
                    }
                    $lowButtons = ([uint32]$nativeEvent.ButtonState -band 0x0000001F)
                    $isMove = ($nativeEvent.EventFlags -eq 0x0001)
                    $isWheel = ($nativeEvent.EventFlags -eq 0x0004 -or $nativeEvent.EventFlags -eq 0x0008)
                    $buttonDown = (($nativeEvent.EventFlags -eq 0 -and $lowButtons -ne 0) -or $nativeDoubleClick)
                    $buttonUp = ($nativeEvent.EventFlags -eq 0 -and $lowButtons -eq 0)
                    $click = (($buttonDown -and -not $isMove -and -not $isWheel) -or $nativeDoubleClick)
                    return (New-InputMouseEvent -X ([int]$nativeEvent.X) -Y ([int]$nativeEvent.Y) -ButtonState ([uint32]$nativeEvent.ButtonState) -ButtonDown $buttonDown -ButtonUp $buttonUp -Click $click -DoubleClick $nativeDoubleClick -WheelDelta $wheelDelta -EventFlags ([uint32]$nativeEvent.EventFlags) -Backend 'Win32' -NativeDoubleClick $nativeDoubleClick)
                }
            }
            catch {
                $script:MouseInputAvailable = $false
                $script:MouseBackend = 'KeyboardOnly'
                Set-MouseFailureReason -Reason ('ReadConsoleInput failed while running: {0}' -f $_.Exception.Message)
                Write-AppLog -Level 'WARN' -Message ('Mouse input read failed; keyboard-only mode active: {0}' -f $script:MouseUnavailableReason)
                Request-FullRedraw
                break
            }
        }
    }

    if ($script:MouseInputAvailable -and $script:MouseBackend -eq 'VT') {
        return (Read-VtInputEvent)
    }

    return (New-InputKeyEvent -KeyInfo (Read-KeySafe))
}

function Read-KeyEventOnly {
    while ($true) {
        $event = Read-InputEvent
        if ($event.Type -eq 'Key') {
            return $event.KeyInfo
        }
        if ($event.Type -eq 'Resize') {
            Request-FullRedraw
            continue
        }
    }
}

function Split-DialogText {
    param(
        [string]$Text,
        [int]$MaxWidth
    )

    $result = New-Object System.Collections.ArrayList
    if ($null -eq $Text) {
        [void]$result.Add('')
        return $result
    }

    $rawLines = [System.Text.RegularExpressions.Regex]::Split($Text, "\r\n|\n|\r")
    foreach ($rawLine in $rawLines) {
        $line = [string]$rawLine
        if ($line.Length -eq 0) {
            [void]$result.Add('')
            continue
        }
        while ($line.Length -gt $MaxWidth) {
            [void]$result.Add($line.Substring(0, $MaxWidth))
            $line = $line.Substring($MaxWidth)
        }
        [void]$result.Add($line)
    }
    return $result
}

function Draw-DialogBox {
    param(
        [string]$Title,
        [string[]]$MessageLines,
        [string]$InputText = $null,
        [int]$InputCursor = 0,
        [int]$InputOffset = 0,
        [string[]]$Buttons = @('OK'),
        [int]$SelectedButton = 0
    )

    $size = Get-ConsoleSizeSafe
    $screenWidth = $size.Width
    $screenHeight = $size.Height
    $maxContent = [Math]::Max(20, [Math]::Min(72, $screenWidth - 8))
    $lines = New-Object System.Collections.ArrayList
    foreach ($messageLine in $MessageLines) {
        $wrapped = Split-DialogText -Text $messageLine -MaxWidth $maxContent
        foreach ($wrappedLine in $wrapped) {
            [void]$lines.Add([string]$wrappedLine)
        }
    }
    if ($lines.Count -eq 0) {
        [void]$lines.Add('')
    }
    $maxDialogLines = [Math]::Max(1, $screenHeight - 7)
    while ($lines.Count -gt $maxDialogLines) {
        $lines.RemoveAt($lines.Count - 1)
    }

    $buttonTexts = @()
    $buttonWidth = 0
    foreach ($button in $Buttons) {
        $buttonText = '[ ' + $button + ' ]'
        $buttonTexts += $buttonText
        $buttonWidth += $buttonText.Length + 1
    }
    if ($buttonWidth -gt 0) {
        $buttonWidth--
    }

    $contentWidth = $Title.Length
    foreach ($line in $lines) {
        if ($line.Length -gt $contentWidth) { $contentWidth = $line.Length }
    }
    if ($null -ne $InputText) {
        $inputLength = $InputText.Length
        if ($inputLength -lt 20) { $inputLength = 20 }
        if ($inputLength -gt $contentWidth) { $contentWidth = $inputLength }
    }
    if ($buttonWidth -gt $contentWidth) { $contentWidth = $buttonWidth }
    if ($contentWidth -gt $maxContent) { $contentWidth = $maxContent }
    if ($contentWidth -lt 24) { $contentWidth = 24 }

    $boxWidth = $contentWidth + 4
    $boxHeight = $lines.Count + 4
    if ($null -ne $InputText) {
        $boxHeight++
    }
    if ($Buttons.Count -gt 0) {
        $boxHeight++
    }

    $left = [Math]::Max(0, [int](($screenWidth - $boxWidth) / 2))
    $top = [Math]::Max(0, [int](($screenHeight - $boxHeight) / 2))
    if (($top + $boxHeight) -gt $screenHeight) {
        $top = [Math]::Max(0, $screenHeight - $boxHeight)
    }

    $border = Get-BorderCharacters
    Write-At -Left $left -Top $top -Text ($border.TopLeft + ($border.Horizontal * ($boxWidth - 2)) + $border.TopRight) -Width $boxWidth -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)
    Write-At -Left ($left + 2) -Top $top -Text (' {0} ' -f $Title) -Width ([Math]::Min($contentWidth, $Title.Length + 2)) -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)

    $bodyTop = $top + 1
    for ($i = 0; $i -lt ($boxHeight - 2); $i++) {
        Write-At -Left $left -Top ($bodyTop + $i) -Text ($border.Vertical + (' ' * ($boxWidth - 2)) + $border.Vertical) -Width $boxWidth -Foreground ([ConsoleColor]::Gray) -Background ([ConsoleColor]::Black)
    }
    Write-At -Left $left -Top ($top + $boxHeight - 1) -Text ($border.BottomLeft + ($border.Horizontal * ($boxWidth - 2)) + $border.BottomRight) -Width $boxWidth -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)

    $row = $bodyTop + 1
    foreach ($line in $lines) {
        Write-At -Left ($left + 2) -Top $row -Text $line -Width $contentWidth -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::Black)
        $row++
    }

    if ($null -ne $InputText) {
        $inputRow = $row
        if ($InputOffset -lt 0) { $InputOffset = 0 }
        if ($InputOffset -gt $InputText.Length) { $InputOffset = $InputText.Length }
        $visibleInput = ''
        if ($InputOffset -lt $InputText.Length) {
            $visibleInput = $InputText.Substring($InputOffset)
        }
        Write-At -Left ($left + 2) -Top $inputRow -Text $visibleInput -Width $contentWidth -Foreground ([ConsoleColor]::Black) -Background ([ConsoleColor]::Gray)
        $script:RenderState.DialogInputZone = [pscustomobject]@{ Left = $left + 2; Right = $left + 1 + $contentWidth; Top = $inputRow; Offset = $InputOffset; Width = $contentWidth }
        try {
            [Console]::CursorVisible = $true
            [Console]::SetCursorPosition([Math]::Min($left + 2 + ($InputCursor - $InputOffset), $left + 1 + $contentWidth), $inputRow)
        }
        catch {
        }
        $row++
    }
    else {
        try { [Console]::CursorVisible = $false } catch {}
        $script:RenderState.DialogInputZone = $null
    }

    $script:RenderState.DialogButtonZones = @()
    if ($Buttons.Count -gt 0) {
        $buttonRow = $top + $boxHeight - 2
        $buttonStart = $left + [int](($boxWidth - $buttonWidth) / 2)
        $buttonLeft = $buttonStart
        for ($i = 0; $i -lt $Buttons.Count; $i++) {
            $fg = [ConsoleColor]::Gray
            $bg = [ConsoleColor]::Black
            if ($i -eq $SelectedButton) {
                $fg = [ConsoleColor]::Black
                $bg = [ConsoleColor]::Cyan
            }
            Write-At -Left $buttonLeft -Top $buttonRow -Text $buttonTexts[$i] -Width $buttonTexts[$i].Length -Foreground $fg -Background $bg
            $script:RenderState.DialogButtonZones += [pscustomobject]@{ Index = $i; Left = $buttonLeft; Right = $buttonLeft + $buttonTexts[$i].Length - 1; Top = $buttonRow }
            $buttonLeft += $buttonTexts[$i].Length + 1
        }
    }
}

function Get-DialogButtonAt {
    param(
        [int]$X,
        [int]$Y
    )

    foreach ($zone in $script:RenderState.DialogButtonZones) {
        if ($Y -eq $zone.Top -and $X -ge $zone.Left -and $X -le $zone.Right) {
            return [int]$zone.Index
        }
    }
    return -1
}

function Get-DialogInputCursorAt {
    param(
        [int]$X,
        [int]$Y,
        [string]$Text
    )

    $zone = $script:RenderState.DialogInputZone
    if ($null -eq $zone) {
        return -1
    }
    if ($Y -ne $zone.Top -or $X -lt $zone.Left -or $X -gt $zone.Right) {
        return -1
    }
    $position = $zone.Offset + ($X - $zone.Left)
    if ($position -lt 0) { $position = 0 }
    if ($position -gt $Text.Length) { $position = $Text.Length }
    return $position
}

function Show-ChoiceDialog {
    param(
        [string]$Title,
        [string[]]$Items
    )

    if ($Items.Count -eq 0) {
        Show-ModalMessage -Message 'No menu items.'
        return -1
    }

    $selected = 0
    $firstVisible = 0
    while ($true) {
        Render-App
        $size = Get-ConsoleSizeSafe
        $screenWidth = $size.Width
        $screenHeight = $size.Height
        $width = [Math]::Min($screenWidth - 4, 70)
        if ($width -lt 30) { $width = [Math]::Max(20, $screenWidth) }
        $height = [Math]::Min($screenHeight - 4, $Items.Count + 4)
        if ($height -lt 6) { $height = 6 }
        $visibleItems = [Math]::Max(1, $height - 2)
        if ($selected -lt $firstVisible) {
            $firstVisible = $selected
        }
        if ($selected -ge ($firstVisible + $visibleItems)) {
            $firstVisible = $selected - $visibleItems + 1
        }
        $left = [Math]::Max(0, [int](($screenWidth - $width) / 2))
        $top = [Math]::Max(0, [int](($screenHeight - $height) / 2))

        $border = Get-BorderCharacters
        Write-At -Left $left -Top $top -Text ($border.TopLeft + ($border.Horizontal * ($width - 2)) + $border.TopRight) -Width $width -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)
        Write-At -Left ($left + 1) -Top $top -Text (' {0} ' -f $Title) -Width ($width - 2) -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)
        for ($i = 0; $i -lt ($height - 2); $i++) {
            $itemIndex = $firstVisible + $i
            $text = ''
            if ($itemIndex -lt $Items.Count) {
                $text = $Items[$itemIndex]
            }
            $fg = [ConsoleColor]::Gray
            $bg = [ConsoleColor]::Black
            if ($itemIndex -eq $selected) {
                $fg = [ConsoleColor]::Black
                $bg = [ConsoleColor]::Cyan
            }
            Write-At -Left $left -Top ($top + 1 + $i) -Text ($border.Vertical + (Truncate-Text -Text $text -Width ($width - 2)) + $border.Vertical) -Width $width -Foreground $fg -Background $bg
        }
        Write-At -Left $left -Top ($top + $height - 1) -Text ($border.BottomLeft + ($border.Horizontal * ($width - 2)) + $border.BottomRight) -Width $width -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)

        $event = Read-InputEvent
        if ($event.Type -eq 'Mouse' -and $event.ButtonDown) {
            if ($event.X -lt $left -or $event.X -ge ($left + $width) -or $event.Y -lt $top -or $event.Y -ge ($top + $height)) {
                Request-FullRedraw
                return -1
            }
            $itemIndex = $firstVisible + ($event.Y - ($top + 1))
            if ($itemIndex -ge 0 -and $itemIndex -lt $Items.Count) {
                Request-FullRedraw
                return $itemIndex
            }
        }
        elseif ($event.Type -eq 'Key') {
            $key = $event.KeyInfo
            switch ($key.Key) {
                ([ConsoleKey]::UpArrow) { if ($selected -gt 0) { $selected-- } }
                ([ConsoleKey]::DownArrow) { if ($selected -lt ($Items.Count - 1)) { $selected++ } }
                ([ConsoleKey]::PageUp) { $selected = [Math]::Max(0, $selected - $visibleItems) }
                ([ConsoleKey]::PageDown) { $selected = [Math]::Min($Items.Count - 1, $selected + $visibleItems) }
                ([ConsoleKey]::Home) { $selected = 0 }
                ([ConsoleKey]::End) { $selected = $Items.Count - 1 }
                ([ConsoleKey]::Enter) { Request-FullRedraw; return $selected }
                ([ConsoleKey]::Escape) { Request-FullRedraw; return -1 }
            }
        }
    }
}

function Show-ModalMessage {
    param(
        [string]$Message
    )

    $selected = 0
    while ($true) {
        Render-App
        Draw-DialogBox -Title 'Message' -MessageLines @($Message) -Buttons @('OK') -SelectedButton $selected
        $event = Read-InputEvent
        if ($event.Type -eq 'Mouse' -and $event.ButtonDown) {
            if ((Get-DialogButtonAt -X $event.X -Y $event.Y) -eq 0) {
                Request-FullRedraw
                return
            }
        }
        elseif ($event.Type -eq 'Key') {
            if ($event.KeyInfo.Key -eq [ConsoleKey]::Enter -or $event.KeyInfo.Key -eq [ConsoleKey]::Escape) {
                Request-FullRedraw
                return
            }
        }
    }
}

function Show-Message {
    param(
        [string]$Message
    )

    Show-ModalMessage -Message $Message
}

function Read-ModalLine {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )

    $text = $Default
    $cursor = $text.Length
    $inputOffset = 0
    $selectedButton = 0
    $selectAll = $false

    while ($true) {
        Render-App
        $size = Get-ConsoleSizeSafe
        $inputWidth = [Math]::Min(72, [Math]::Max(20, $size.Width - 12))
        if ($cursor -lt $inputOffset) {
            $inputOffset = $cursor
        }
        if ($cursor -ge ($inputOffset + $inputWidth)) {
            $inputOffset = $cursor - $inputWidth + 1
        }
        Draw-DialogBox -Title 'Input' -MessageLines @($Prompt) -InputText $text -InputCursor $cursor -InputOffset $inputOffset -Buttons @('OK', 'Cancel') -SelectedButton $selectedButton
        $event = Read-InputEvent
        if ($event.Type -eq 'Mouse' -and $event.ButtonDown) {
            $inputCursor = Get-DialogInputCursorAt -X $event.X -Y $event.Y -Text $text
            if ($inputCursor -ge 0) {
                $cursor = $inputCursor
                $selectedButton = 0
                $selectAll = $false
                continue
            }
            $button = Get-DialogButtonAt -X $event.X -Y $event.Y
            if ($button -eq 0) {
                try { [Console]::CursorVisible = $false } catch {}
                Request-FullRedraw
                return $text
            }
            if ($button -eq 1) {
                try { [Console]::CursorVisible = $false } catch {}
                Request-FullRedraw
                return $null
            }
            continue
        }

        if ($event.Type -ne 'Key') {
            continue
        }

        $key = $event.KeyInfo
        $control = (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
        switch ($key.Key) {
            ([ConsoleKey]::Enter) {
                try { [Console]::CursorVisible = $false } catch {}
                Request-FullRedraw
                if ($selectedButton -eq 0) { return $text }
                return $null
            }
            ([ConsoleKey]::Escape) {
                try { [Console]::CursorVisible = $false } catch {}
                Request-FullRedraw
                return $null
            }
            ([ConsoleKey]::Tab) { if ($selectedButton -eq 0) { $selectedButton = 1 } else { $selectedButton = 0 } }
            ([ConsoleKey]::LeftArrow) {
                if ($control) {
                    $cursor = 0
                }
                elseif ($cursor -gt 0) {
                    $cursor--
                }
                $selectedButton = 0
                $selectAll = $false
            }
            ([ConsoleKey]::RightArrow) {
                if ($control) {
                    $cursor = $text.Length
                }
                elseif ($cursor -lt $text.Length) {
                    $cursor++
                }
                $selectedButton = 0
                $selectAll = $false
            }
            ([ConsoleKey]::Home) {
                $cursor = 0
                $selectedButton = 0
                $selectAll = $false
            }
            ([ConsoleKey]::End) {
                $cursor = $text.Length
                $selectedButton = 0
                $selectAll = $false
            }
            ([ConsoleKey]::Backspace) {
                if ($selectAll) {
                    $text = ''
                    $cursor = 0
                    $selectAll = $false
                }
                elseif ($cursor -gt 0) {
                    $text = $text.Remove($cursor - 1, 1)
                    $cursor--
                }
            }
            ([ConsoleKey]::Delete) {
                if ($selectAll) {
                    $text = ''
                    $cursor = 0
                    $selectAll = $false
                }
                elseif ($cursor -lt $text.Length) {
                    $text = $text.Remove($cursor, 1)
                }
            }
            default {
                if ($control -and $key.Key -eq [ConsoleKey]::A) {
                    $selectAll = $true
                    $cursor = 0
                }
                elseif ($control -and $key.Key -eq [ConsoleKey]::V) {
                    $clipText = ''
                    try {
                        if ($null -ne (Get-Command -Name Get-Clipboard -ErrorAction SilentlyContinue)) {
                            $clipText = [string](Get-Clipboard -Raw -ErrorAction Stop)
                        }
                    }
                    catch {
                        $clipText = ''
                    }
                    if (-not [string]::IsNullOrEmpty($clipText)) {
                        $clipText = $clipText.Replace("`r", '').Replace("`n", ' ')
                        if ($selectAll) {
                            $text = $clipText
                            $cursor = $text.Length
                            $selectAll = $false
                        }
                        else {
                            $text = $text.Insert($cursor, $clipText)
                            $cursor += $clipText.Length
                        }
                    }
                }
                elseif (-not [char]::IsControl($key.KeyChar)) {
                    if ($selectAll) {
                        $text = ''
                        $cursor = 0
                        $selectAll = $false
                    }
                    $text = $text.Insert($cursor, [string]$key.KeyChar)
                    $cursor++
                    $selectedButton = 0
                }
            }
        }
    }
}

function Read-DialogLine {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )

    return (Read-ModalLine -Prompt $Prompt -Default $Default)
}

function Confirm-ModalDialog {
    param(
        [string]$Message,
        [bool]$DefaultYes = $false
    )

    $selected = 1
    if ($DefaultYes) {
        $selected = 0
    }

    while ($true) {
        Render-App
        Draw-DialogBox -Title 'Confirm' -MessageLines @($Message) -Buttons @('Yes', 'No') -SelectedButton $selected
        $event = Read-InputEvent
        if ($event.Type -eq 'Mouse' -and $event.ButtonDown) {
            $button = Get-DialogButtonAt -X $event.X -Y $event.Y
            if ($button -eq 0) { Request-FullRedraw; return $true }
            if ($button -eq 1) { Request-FullRedraw; return $false }
            continue
        }
        if ($event.Type -ne 'Key') {
            continue
        }
        $key = $event.KeyInfo
        if ($key.Key -eq [ConsoleKey]::Enter) {
            Request-FullRedraw
            return ($selected -eq 0)
        }
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Request-FullRedraw
            return $false
        }
        if ($key.Key -eq [ConsoleKey]::LeftArrow -or $key.Key -eq [ConsoleKey]::RightArrow -or $key.Key -eq [ConsoleKey]::Tab) {
            if ($selected -eq 0) { $selected = 1 } else { $selected = 0 }
        }
        if ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y') {
            Request-FullRedraw
            return $true
        }
        if ($key.KeyChar -eq 'n' -or $key.KeyChar -eq 'N') {
            Request-FullRedraw
            return $false
        }
    }
}

function Confirm-Dialog {
    param(
        [string]$Message,
        [bool]$DefaultYes = $false,
        [bool]$AssumeYes = $false
    )

    if ($AssumeYes) {
        return $true
    }

    return (Confirm-ModalDialog -Message $Message -DefaultYes $DefaultYes)
}

function Show-OverwriteDialog {
    param(
        [string]$Destination
    )

    $buttons = @('Overwrite', 'Overwrite All', 'Skip', 'Skip All', 'Cancel')
    $selected = 0
    while ($true) {
        Render-App
        Draw-DialogBox -Title 'Overwrite' -MessageLines @(('Target exists:'), $Destination) -Buttons $buttons -SelectedButton $selected
        $event = Read-InputEvent
        if ($event.Type -eq 'Mouse' -and $event.ButtonDown) {
            $button = Get-DialogButtonAt -X $event.X -Y $event.Y
            if ($button -ge 0) {
                Request-FullRedraw
                return $buttons[$button]
            }
        }
        elseif ($event.Type -eq 'Key') {
            $key = $event.KeyInfo
            switch ($key.Key) {
                ([ConsoleKey]::LeftArrow) { if ($selected -gt 0) { $selected-- } }
                ([ConsoleKey]::RightArrow) { if ($selected -lt ($buttons.Count - 1)) { $selected++ } }
                ([ConsoleKey]::Tab) { $selected++; if ($selected -ge $buttons.Count) { $selected = 0 } }
                ([ConsoleKey]::Enter) { Request-FullRedraw; return $buttons[$selected] }
                ([ConsoleKey]::Escape) { Request-FullRedraw; return 'Cancel' }
                default {
                    switch ([char]::ToUpperInvariant($key.KeyChar)) {
                        'O' { Request-FullRedraw; return 'Overwrite' }
                        'A' { Request-FullRedraw; return 'Overwrite All' }
                        'S' { Request-FullRedraw; return 'Skip' }
                        'K' { Request-FullRedraw; return 'Skip All' }
                        'C' { Request-FullRedraw; return 'Cancel' }
                    }
                }
            }
        }
    }
}

function Show-ProgressDialog {
    param(
        [string]$Operation,
        [string]$CurrentItem,
        [int]$Index,
        [int]$Total
    )

    Render-App
    Draw-DialogBox -Title 'Progress' -MessageLines @($Operation, ('{0}/{1}' -f $Index, $Total), $CurrentItem, 'Press Esc between items to cancel when prompted.') -Buttons @() -SelectedButton 0
}

function Test-CancelKeyPending {
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape) {
                return $true
            }
        }
    }
    catch {
    }
    return $false
}

function Show-MenuList {
    param(
        [string]$Title,
        [string[]]$Items
    )

    return (Show-ChoiceDialog -Title $Title -Items $Items)
}

function Get-SelectedOrMarkedItems {
    param(
        [hashtable]$Panel
    )

    $markedItems = @()
    foreach ($item in $Panel.Items) {
        if (-not $item.IsParent -and $Panel.Marks.ContainsKey($item.FullName)) {
            $markedItems += ,$item
        }
    }

    if ($markedItems.Count -gt 0) {
        return $markedItems
    }

    $current = Get-CurrentItem -Panel $Panel
    if ($null -eq $current -or $current.IsParent) {
        return @()
    }
    return @($current)
}

function Toggle-MarkCurrent {
    param(
        [hashtable]$Panel,
        [bool]$MoveDown
    )

    $item = Get-CurrentItem -Panel $Panel
    if ($null -eq $item -or $item.IsParent) {
        return
    }

    if ($Panel.Marks.ContainsKey($item.FullName)) {
        $Panel.Marks.Remove($item.FullName)
    }
    else {
        $Panel.Marks[$item.FullName] = $true
    }

    if ($MoveDown) {
        Move-Selection -Panel $Panel -Delta 1 -VisibleRows $script:State.VisibleRows
    }
}

function Select-Group {
    param(
        [hashtable]$Panel,
        [bool]$Unselect
    )

    $pattern = Read-DialogLine -Prompt 'Pattern (wildcard or regex, prefix r: for regex)' -Default '*'
    if ($null -eq $pattern) {
        return
    }

    $useRegex = $false
    if ($pattern.StartsWith('r:')) {
        $useRegex = $true
        $pattern = $pattern.Substring(2)
    }

    foreach ($item in $Panel.Items) {
        if ($item.IsParent) {
            continue
        }
        $matches = $false
        if ($useRegex) {
            try {
                $matches = [System.Text.RegularExpressions.Regex]::IsMatch($item.Name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
            catch {
                Show-Message -Message 'Invalid regex.'
                return
            }
        }
        else {
            $matches = ($item.Name -like $pattern)
        }

        if ($matches) {
            if ($Unselect) {
                if ($Panel.Marks.ContainsKey($item.FullName)) {
                    $Panel.Marks.Remove($item.FullName)
                }
            }
            else {
                $Panel.Marks[$item.FullName] = $true
            }
        }
    }
}

function Show-FilterDialog {
    param(
        [hashtable]$Panel
    )

    while ($true) {
        $mode = 'wildcard'
        if ($Panel.FilterRegex) { $mode = 'regex' }
        $caseText = 'case-insensitive'
        if ($Panel.CaseSensitive) { $caseText = 'case-sensitive' }
        $current = '[none]'
        if (-not [string]::IsNullOrWhiteSpace($Panel.FilterPattern)) {
            $current = ('{0}, {1}, {2}' -f $mode, $caseText, $Panel.FilterPattern)
        }
        $choice = Show-MenuList -Title ('Filter: {0}' -f $current) -Items @(
            'Set wildcard filter',
            'Set regex filter',
            'Toggle case sensitivity',
            'Clear filter',
            'Back'
        )
        switch ($choice) {
            0 {
                $value = Read-DialogLine -Prompt 'Wildcard filter' -Default $Panel.FilterPattern
                if ($null -ne $value) {
                    $Panel.FilterPattern = $value
                    $Panel.FilterRegex = $false
                    Refresh-Panel -Panel $Panel
                }
            }
            1 {
                $value = Read-DialogLine -Prompt 'Regex filter' -Default $Panel.FilterPattern
                if ($null -ne $value) {
                    try {
                        [void](New-Object System.Text.RegularExpressions.Regex($value))
                        $Panel.FilterPattern = $value
                        $Panel.FilterRegex = $true
                        Refresh-Panel -Panel $Panel
                    }
                    catch {
                        Show-Message -Message 'Invalid regex.'
                    }
                }
            }
            2 {
                $Panel.CaseSensitive = -not [bool]$Panel.CaseSensitive
                Refresh-Panel -Panel $Panel
            }
            3 {
                $Panel.FilterPattern = ''
                $Panel.FilterRegex = $false
                Refresh-Panel -Panel $Panel
            }
            default { return }
        }
    }
}

function Invert-Selection {
    param(
        [hashtable]$Panel
    )

    foreach ($item in $Panel.Items) {
        if ($item.IsParent) {
            continue
        }
        if ($Panel.Marks.ContainsKey($item.FullName)) {
            $Panel.Marks.Remove($item.FullName)
        }
        else {
            $Panel.Marks[$item.FullName] = $true
        }
    }
}

function Get-OperationSummary {
    param(
        [object[]]$Items
    )

    $count = 0
    $bytes = 0
    foreach ($item in $Items) {
        try {
            if ($item.IsDirectory) {
                $stack = New-Object System.Collections.Stack
                $stack.Push($item.FullName)
                while ($stack.Count -gt 0) {
                    $currentPath = [string]$stack.Pop()
                    $currentInfo = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
                    $count++
                    if (($currentInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }
                    $children = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop)
                    foreach ($child in $children) {
                        if (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                            $stack.Push($child.FullName)
                        }
                        else {
                            $count++
                            $bytes += [long]$child.Length
                        }
                    }
                }
            }
            else {
                $count++
                $bytes += [long]$item.Length
            }
        }
        catch {
            Write-AppLog -Level 'WARN' -Message ('Summary skipped {0}: {1}' -f $item.FullName, $_.Exception.Message)
        }
    }

    return @{ Count = $count; Bytes = $bytes }
}

function Get-OverwriteDecision {
    param(
        [string]$Destination,
        [ref]$OverwritePolicy,
        [bool]$AssumeYes = $false
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        return 'Write'
    }

    if ($OverwritePolicy.Value -eq 'OverwriteAll') {
        return 'Overwrite'
    }
    if ($OverwritePolicy.Value -eq 'SkipAll') {
        return 'Skip'
    }
    if ($AssumeYes) {
        return 'Overwrite'
    }

    while ($true) {
        $decision = Show-OverwriteDialog -Destination $Destination
        switch ($decision) {
            'Overwrite' { return 'Overwrite' }
            'Overwrite All' { $OverwritePolicy.Value = 'OverwriteAll'; return 'Overwrite' }
            'Skip' { return 'Skip' }
            'Skip All' { $OverwritePolicy.Value = 'SkipAll'; return 'Skip' }
            default { return 'Cancel' }
        }
    }
}

function Copy-FileSafe {
    param(
        [string]$Source,
        [string]$Destination,
        [ref]$OverwritePolicy,
        [bool]$AssumeYes = $false,
        [switch]$SimulateFailureAfterBackup
    )

    $temporaryPath = $null
    $backupPath = $null
    try {
        $decision = Get-OverwriteDecision -Destination $Destination -OverwritePolicy $OverwritePolicy -AssumeYes $AssumeYes
        if ($decision -eq 'Cancel') {
            return 'Cancel'
        }
        if ($decision -eq 'Skip') {
            return 'Skipped'
        }

        $parent = Split-Path -Path $Destination -Parent
        New-DirectoryIfMissing -Path $parent

        $sourceInfo = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        $temporaryPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'copy_incoming'
        Copy-Item -LiteralPath $Source -Destination $temporaryPath -Force -ErrorAction Stop
        $tempInfo = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        if ([long]$tempInfo.Length -ne [long]$sourceInfo.Length) {
            throw 'Temporary copy validation failed.'
        }

        if (Test-Path -LiteralPath $Destination) {
            $backupPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'copy_backup'
            Move-Item -LiteralPath $Destination -Destination $backupPath -Force -ErrorAction Stop
            Write-AppLog -Level 'WARN' -Message ('Copy overwrite backup created: {0}' -f $backupPath)
        }
        if ($SimulateFailureAfterBackup.IsPresent) {
            throw 'Simulated copy failure after backup.'
        }

        Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force -ErrorAction Stop
        $destInfo = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
        if ([long]$destInfo.Length -ne [long]$sourceInfo.Length) {
            throw 'Final copy validation failed.'
        }
        $destInfo.LastWriteTime = $sourceInfo.LastWriteTime
        $destInfo.Attributes = $sourceInfo.Attributes
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        }
        return 'Copied'
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Copy file failed {0} -> {1}: {2}' -f $Source, $Destination, $_.Exception.Message)
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            [void](Restore-MoveBackup -BackupPath $backupPath -Destination $Destination -Reason $_.Exception.Message)
        }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            try {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
            catch {
                Write-AppLog -Level 'WARN' -Message ('Temporary copy file cleanup failed {0}: {1}' -f $temporaryPath, $_.Exception.Message)
            }
        }
        return 'Error'
    }
}

function Copy-DirectorySafe {
    param(
        [string]$Source,
        [string]$Destination,
        [ref]$OverwritePolicy,
        [bool]$AssumeYes = $false
    )

    $temporaryPath = $null
    $backupPath = $null
    try {
        $sourceInfo = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        if (($sourceInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-AppLog -Level 'WARN' -Message ('Reparse directory skipped during copy: {0}' -f $Source)
            return 'Skipped'
        }

        if (Test-Path -LiteralPath $Destination) {
            $decision = Get-OverwriteDecision -Destination $Destination -OverwritePolicy $OverwritePolicy -AssumeYes $AssumeYes
            if ($decision -eq 'Cancel') {
                return 'Cancel'
            }
            if ($decision -eq 'Skip') {
                return 'Skipped'
            }

            $temporaryPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'copy_dir_incoming'
            New-DirectoryIfMissing -Path $temporaryPath
            $childrenForTemp = @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)
            foreach ($childForTemp in $childrenForTemp) {
                $tempTarget = Join-Path -Path $temporaryPath -ChildPath $childForTemp.Name
                if (($childForTemp.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $tempResult = Copy-DirectorySafe -Source $childForTemp.FullName -Destination $tempTarget -OverwritePolicy $OverwritePolicy -AssumeYes $true
                }
                else {
                    $tempResult = Copy-FileSafe -Source $childForTemp.FullName -Destination $tempTarget -OverwritePolicy $OverwritePolicy -AssumeYes $true
                }
                if ($tempResult -eq 'Cancel' -or $tempResult -eq 'Error') {
                    throw ('Temporary directory copy failed for {0}' -f $childForTemp.FullName)
                }
            }
            $tempInfo = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            $tempInfo.LastWriteTime = $sourceInfo.LastWriteTime
            $tempInfo.Attributes = $sourceInfo.Attributes
            if (-not (Test-MoveDestinationValid -Source $Source -Destination $temporaryPath)) {
                throw 'Temporary directory copy validation failed.'
            }
            $backupPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'copy_dir_backup'
            Move-Item -LiteralPath $Destination -Destination $backupPath -Force -ErrorAction Stop
            Write-AppLog -Level 'WARN' -Message ('Directory copy overwrite backup created: {0}' -f $backupPath)
            Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force -ErrorAction Stop
            if (-not (Test-MoveDestinationValid -Source $Source -Destination $Destination)) {
                throw 'Final directory copy validation failed.'
            }
            Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction Stop
            return 'Copied'
        }

        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
            New-DirectoryIfMissing -Path $Destination
        }

        $children = @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)
        foreach ($child in $children) {
            $target = Join-Path -Path $Destination -ChildPath $child.Name
            if (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $result = Copy-DirectorySafe -Source $child.FullName -Destination $target -OverwritePolicy $OverwritePolicy -AssumeYes $AssumeYes
            }
            else {
                $result = Copy-FileSafe -Source $child.FullName -Destination $target -OverwritePolicy $OverwritePolicy -AssumeYes $AssumeYes
            }
            if ($result -eq 'Cancel') {
                return 'Cancel'
            }
        }

        $destInfo = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
        $destInfo.LastWriteTime = $sourceInfo.LastWriteTime
        $destInfo.Attributes = $sourceInfo.Attributes
        return 'Copied'
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Copy directory failed {0} -> {1}: {2}' -f $Source, $Destination, $_.Exception.Message)
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            [void](Restore-MoveBackup -BackupPath $backupPath -Destination $Destination -Reason $_.Exception.Message)
        }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            try {
                Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-AppLog -Level 'WARN' -Message ('Temporary copy directory cleanup failed {0}: {1}' -f $temporaryPath, $_.Exception.Message)
            }
        }
        return 'Error'
    }
}

function Copy-ItemsToDirectory {
    param(
        [object[]]$Items,
        [string]$DestinationDirectory,
        [bool]$AssumeYes = $false
    )

    if ($Items.Count -eq 0) {
        return $true
    }

    $summary = Get-OperationSummary -Items $Items
    $skipConfirm = ($AssumeYes -or (-not [bool]$script:Config.ConfirmCopy))
    if (-not (Confirm-Dialog -Message ('Copy {0} items ({1} bytes) to {2}?' -f $summary.Count, $summary.Bytes, $DestinationDirectory) -DefaultYes $false -AssumeYes $skipConfirm)) {
        return $false
    }

    New-DirectoryIfMissing -Path $DestinationDirectory
    $overwritePolicy = 'Ask'
    $copiedCount = 0
    $skippedCount = 0
    $errorCount = 0
    for ($itemIndex = 0; $itemIndex -lt $Items.Count; $itemIndex++) {
        $item = $Items[$itemIndex]
        if (-not $AssumeYes) {
            Show-ProgressDialog -Operation 'Copy' -CurrentItem $item.FullName -Index ($itemIndex + 1) -Total $Items.Count
            if (Test-CancelKeyPending) {
                Show-Message -Message ('Copy canceled. Copied {0}, skipped {1}, errors {2}.' -f $copiedCount, $skippedCount, $errorCount)
                return $false
            }
        }
        $target = Join-Path -Path $DestinationDirectory -ChildPath $item.Name
        if ($item.IsDirectory) {
            $result = Copy-DirectorySafe -Source $item.FullName -Destination $target -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $AssumeYes
        }
        else {
            $result = Copy-FileSafe -Source $item.FullName -Destination $target -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $AssumeYes
        }
        if ($result -eq 'Cancel') {
            return $false
        }
        if ($result -eq 'Copied') { $copiedCount++ }
        elseif ($result -eq 'Skipped') { $skippedCount++ }
        elseif ($result -eq 'Error') { $errorCount++ }
    }
    if (-not $AssumeYes -and -not $script:NonInteractiveMode) {
        Show-Message -Message ('Copy complete. Copied {0}, skipped {1}, errors {2}.' -f $copiedCount, $skippedCount, $errorCount)
    }
    return $true
}

function Remove-PathSafe {
    param(
        [string]$Path,
        [bool]$UseSafeDelete,
        [bool]$AssumeYes = $false
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($UseSafeDelete) {
            $trashRoot = Join-Path -Path $script:LocalDataPath -ChildPath 'Trash'
            $metadataRoot = Join-Path -Path $trashRoot -ChildPath '_metadata'
            New-DirectoryIfMissing -Path $trashRoot
            New-DirectoryIfMissing -Path $metadataRoot
            $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
            $trashName = '{0}_{1}' -f $stamp, $item.Name
            $trashPath = Join-Path -Path $trashRoot -ChildPath $trashName
            Move-Item -LiteralPath $Path -Destination $trashPath -Force -ErrorAction Stop
            $metadata = @{
                OriginalPath = $item.FullName
                TrashPath = $trashPath
                DeletedAt = (Get-Date).ToString('o')
                IsDirectory = (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            }
            $metadataPath = Join-Path -Path $metadataRoot -ChildPath ($trashName + '.json')
            ($metadata | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $metadataPath -Encoding UTF8 -ErrorAction Stop
            return 'Deleted'
        }

        if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
        }
        else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        return 'Deleted'
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Delete failed {0}: {1}' -f $Path, $_.Exception.Message)
        return 'Error'
    }
}

function Delete-ItemsSafe {
    param(
        [object[]]$Items,
        [bool]$AssumeYes = $false
    )

    if ($Items.Count -eq 0) {
        return $true
    }

    $summary = Get-OperationSummary -Items $Items
    $mode = 'permanent delete'
    if ($script:Config.SafeDelete) {
        $mode = 'safe delete'
    }

    $skipConfirm = ($AssumeYes -or (-not [bool]$script:Config.ConfirmDelete))
    if (-not (Confirm-Dialog -Message ('{0} {1} items ({2} bytes)?' -f $mode, $summary.Count, $summary.Bytes) -DefaultYes $false -AssumeYes $skipConfirm)) {
        return $false
    }

    $deletedCount = 0
    $skippedCount = 0
    $errorCount = 0
    for ($itemIndex = 0; $itemIndex -lt $Items.Count; $itemIndex++) {
        $item = $Items[$itemIndex]
        if (-not $AssumeYes) {
            Show-ProgressDialog -Operation 'Delete' -CurrentItem $item.FullName -Index ($itemIndex + 1) -Total $Items.Count
            if (Test-CancelKeyPending) {
                Show-Message -Message ('Delete canceled. Deleted {0}, skipped {1}, errors {2}.' -f $deletedCount, $skippedCount, $errorCount)
                return $false
            }
        }
        $result = Remove-PathSafe -Path $item.FullName -UseSafeDelete ([bool]$script:Config.SafeDelete) -AssumeYes $AssumeYes
        if ($result -eq 'Deleted') { $deletedCount++ }
        elseif ($result -eq 'Skipped') { $skippedCount++ }
        else { $errorCount++ }
    }
    if (-not $AssumeYes -and -not $script:NonInteractiveMode) {
        Show-Message -Message ('Delete complete. Deleted {0}, skipped {1}, errors {2}.' -f $deletedCount, $skippedCount, $errorCount)
    }
    return $true
}

function New-SiblingTemporaryPath {
    param(
        [string]$Path,
        [string]$Purpose
    )

    $parent = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) {
        $parent = (Get-Location).ProviderPath
    }
    $leaf = Split-Path -Path $Path -Leaf
    for ($i = 0; $i -lt 100; $i++) {
        $candidate = Join-Path -Path $parent -ChildPath ('.cc_{0}_{1}_{2}_{3}' -f $Purpose, (Get-Date).ToString('yyyyMMddHHmmssfff'), $i, $leaf)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw ('Cannot create temporary path near {0}' -f $Path)
}

function Get-PathSummarySafe {
    param(
        [string]$Path
    )

    $summary = @{
        Exists = $false
        IsDirectory = $false
        Count = 0
        Bytes = 0
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $summary
    }

    $summary.Exists = $true
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $summary.IsDirectory = (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
    if (-not $summary.IsDirectory) {
        $summary.Count = 1
        $summary.Bytes = [long]$item.Length
        return $summary
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $currentPath = [string]$stack.Pop()
        $currentInfo = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        $summary.Count++
        if (($currentInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }
        $children = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($child.FullName)
            }
            else {
                $summary.Count++
                $summary.Bytes += [long]$child.Length
            }
        }
    }

    return $summary
}

function Test-MoveDestinationValid {
    param(
        [string]$Source,
        [string]$Destination
    )

    try {
        $sourceSummary = Get-PathSummarySafe -Path $Source
        $destinationSummary = Get-PathSummarySafe -Path $Destination
        if (-not $destinationSummary.Exists) {
            return $false
        }
        if ($sourceSummary.IsDirectory -ne $destinationSummary.IsDirectory) {
            return $false
        }
        if ($sourceSummary.Count -ne $destinationSummary.Count) {
            return $false
        }
        if ($sourceSummary.Bytes -ne $destinationSummary.Bytes) {
            return $false
        }
        return $true
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ('Move validation failed {0} -> {1}: {2}' -f $Source, $Destination, $_.Exception.Message)
        return $false
    }
}

function Copy-PathToTemporaryDestination {
    param(
        [string]$Source,
        [string]$TemporaryDestination
    )

    $overwritePolicy = 'Ask'
    $sourceInfo = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if (($sourceInfo.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        $result = Copy-DirectorySafe -Source $Source -Destination $TemporaryDestination -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true
    }
    else {
        $result = Copy-FileSafe -Source $Source -Destination $TemporaryDestination -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true
    }
    return ($result -eq 'Copied')
}

function Restore-MoveBackup {
    param(
        [string]$BackupPath,
        [string]$Destination,
        [string]$Reason
    )

    Write-AppLog -Level 'WARN' -Message ('Move rollback attempt for {0}: {1}' -f $Destination, $Reason)
    try {
        if (Test-Path -LiteralPath $Destination) {
            $failedPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'failed'
            Move-Item -LiteralPath $Destination -Destination $failedPath -Force -ErrorAction Stop
            Write-AppLog -Level 'WARN' -Message ('Moved failed destination aside: {0}' -f $failedPath)
        }
        if (Test-Path -LiteralPath $BackupPath) {
            Move-Item -LiteralPath $BackupPath -Destination $Destination -Force -ErrorAction Stop
            Write-AppLog -Level 'WARN' -Message ('Rollback restored destination: {0}' -f $Destination)
            return $true
        }
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Rollback failed for {0}: {1}' -f $Destination, $_.Exception.Message)
        Show-Message -Message ('Rollback failed. Check log and backup: {0}' -f $BackupPath)
        return $false
    }

    return $false
}

function Test-SameLiteralPath {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    try {
        $leftFull = [System.IO.Path]::GetFullPath($LeftPath).TrimEnd('\')
        $rightFull = [System.IO.Path]::GetFullPath($RightPath).TrimEnd('\')
        return ([string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase))
    }
    catch {
        return $false
    }
}

function Move-PathSafe {
    param(
        [string]$Source,
        [string]$Destination,
        [ref]$OverwritePolicy,
        [bool]$AssumeYes = $false,
        [bool]$ForceCopyFallback = $false,
        [switch]$SimulateFailureAfterBackup
    )

    $backupPath = $null
    $temporaryPath = $null
    try {
        if (Test-SameLiteralPath -LeftPath $Source -RightPath $Destination) {
            Write-AppLog -Level 'INFO' -Message ('Move skipped because source and destination are identical: {0}' -f $Source)
            return 'Skipped'
        }
        $decision = Get-OverwriteDecision -Destination $Destination -OverwritePolicy $OverwritePolicy -AssumeYes $AssumeYes
        if ($decision -eq 'Cancel') {
            return 'Cancel'
        }
        if ($decision -eq 'Skip') {
            return 'Skipped'
        }

        $parent = Split-Path -Path $Destination -Parent
        New-DirectoryIfMissing -Path $parent

        if ((-not $ForceCopyFallback) -and -not (Test-Path -LiteralPath $Destination)) {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $Destination) {
                return 'Moved'
            }
            throw 'Move completed but destination validation failed.'
        }

        $temporaryPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'incoming'
        if (-not (Copy-PathToTemporaryDestination -Source $Source -TemporaryDestination $temporaryPath)) {
            throw 'Copy to temporary destination failed.'
        }
        if (-not (Test-MoveDestinationValid -Source $Source -Destination $temporaryPath)) {
            throw 'Temporary destination validation failed.'
        }

        if (Test-Path -LiteralPath $Destination) {
            $backupPath = New-SiblingTemporaryPath -Path $Destination -Purpose 'backup'
            Move-Item -LiteralPath $Destination -Destination $backupPath -Force -ErrorAction Stop
            Write-AppLog -Level 'WARN' -Message ('Move fallback backup created: {0}' -f $backupPath)
        }
        if ($SimulateFailureAfterBackup.IsPresent) {
            throw 'Simulated fallback move failure after backup.'
        }

        Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force -ErrorAction Stop
        if (-not (Test-MoveDestinationValid -Source $Source -Destination $Destination)) {
            throw 'Final destination validation failed.'
        }
        [void](Remove-PathSafe -Path $Source -UseSafeDelete $false -AssumeYes $true)
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction Stop
        }
        return 'Moved'
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Move failed {0} -> {1}: {2}' -f $Source, $Destination, $_.Exception.Message)
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            [void](Restore-MoveBackup -BackupPath $backupPath -Destination $Destination -Reason $_.Exception.Message)
        }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            try {
                Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-AppLog -Level 'WARN' -Message ('Temporary move path cleanup failed {0}: {1}' -f $temporaryPath, $_.Exception.Message)
            }
        }
        return 'Error'
    }
}

function Move-ItemsToDirectory {
    param(
        [object[]]$Items,
        [string]$DestinationDirectory,
        [bool]$AssumeYes = $false
    )

    if ($Items.Count -eq 0) {
        return $true
    }

    $summary = Get-OperationSummary -Items $Items
    $skipConfirm = ($AssumeYes -or (-not [bool]$script:Config.ConfirmMove))
    if (-not (Confirm-Dialog -Message ('Move {0} items ({1} bytes) to {2}?' -f $summary.Count, $summary.Bytes, $DestinationDirectory) -DefaultYes $false -AssumeYes $skipConfirm)) {
        return $false
    }

    New-DirectoryIfMissing -Path $DestinationDirectory
    $overwritePolicy = 'Ask'
    $movedCount = 0
    $skippedCount = 0
    $errorCount = 0
    for ($itemIndex = 0; $itemIndex -lt $Items.Count; $itemIndex++) {
        $item = $Items[$itemIndex]
        if (-not $AssumeYes) {
            Show-ProgressDialog -Operation 'Move' -CurrentItem $item.FullName -Index ($itemIndex + 1) -Total $Items.Count
            if (Test-CancelKeyPending) {
                Show-Message -Message ('Move canceled. Moved {0}, skipped {1}, errors {2}.' -f $movedCount, $skippedCount, $errorCount)
                return $false
            }
        }
        $target = Join-Path -Path $DestinationDirectory -ChildPath $item.Name
        $result = Move-PathSafe -Source $item.FullName -Destination $target -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $AssumeYes
        if ($result -eq 'Cancel') {
            return $false
        }
        if ($result -eq 'Moved') { $movedCount++ }
        elseif ($result -eq 'Skipped') { $skippedCount++ }
        elseif ($result -eq 'Error') { $errorCount++ }
    }
    if (-not $AssumeYes -and -not $script:NonInteractiveMode) {
        Show-Message -Message ('Move complete. Moved {0}, skipped {1}, errors {2}.' -f $movedCount, $skippedCount, $errorCount)
    }
    return $true
}

function New-DirectorySafe {
    param(
        [string]$ParentPath,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    foreach ($invalid in [System.IO.Path]::GetInvalidFileNameChars()) {
        if ($Name.IndexOf($invalid) -ge 0) {
            Show-Message -Message 'Invalid directory name.'
            return $false
        }
    }

    try {
        $target = Join-Path -Path $ParentPath -ChildPath $Name
        New-DirectoryIfMissing -Path $target
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Mkdir failed {0}: {1}' -f $Name, $_.Exception.Message)
        Show-Message -Message ('Cannot create directory: {0}' -f $_.Exception.Message)
        return $false
    }
}

function New-FileSafe {
    param(
        [string]$ParentPath,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    try {
        $target = Join-Path -Path $ParentPath -ChildPath $Name
        if (Test-Path -LiteralPath $target) {
            Show-Message -Message 'File already exists.'
            return $false
        }
        $encoding = Get-DefaultFileEncodingName
        Set-Content -LiteralPath $target -Value '' -Encoding $encoding -ErrorAction Stop
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('New file failed {0}: {1}' -f $Name, $_.Exception.Message)
        Show-Message -Message ('Cannot create file: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Get-DefaultFileEncodingName {
    $encoding = [string]$script:Config.DefaultEncoding
    switch ($encoding.ToUpperInvariant()) {
        'ASCII' { return 'ASCII' }
        'UTF8BOM' { return 'UTF8' }
        'UTF16LE' { return 'Unicode' }
        'UNICODE' { return 'Unicode' }
        default { return 'UTF8' }
    }
}

function Get-DefaultTextEncodingObject {
    $encoding = [string]$script:Config.DefaultEncoding
    switch ($encoding.ToUpperInvariant()) {
        'ASCII' { return [System.Text.Encoding]::ASCII }
        'UTF8BOM' { return New-Object System.Text.UTF8Encoding($true) }
        'UTF16LE' { return [System.Text.Encoding]::Unicode }
        'UNICODE' { return [System.Text.Encoding]::Unicode }
        default { return New-Object System.Text.UTF8Encoding($false) }
    }
}

function Initialize-ZipSupport {
    if ($script:ZipAssembliesLoaded) {
        return $true
    }

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $script:ZipAssembliesLoaded = $true
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('ZIP support unavailable: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Get-RelativePathSafe {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [System.IO.Path]::DirectorySeparatorChar
    }
    $targetFull = [System.IO.Path]::GetFullPath($FullPath)
    $baseUri = New-Object System.Uri($baseFull)
    $targetUri = New-Object System.Uri($targetFull)
    $relative = $baseUri.MakeRelativeUri($targetUri).ToString()
    return [System.Uri]::UnescapeDataString($relative).Replace('\', '/')
}

function Add-PathToZip {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$Path,
        [string]$BasePath
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-AppLog -Level 'WARN' -Message ('Reparse directory skipped for ZIP: {0}' -f $Path)
            return
        }
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        foreach ($child in $children) {
            Add-PathToZip -Zip $Zip -Path $child.FullName -BasePath $BasePath
        }
    }
    else {
        $entryName = Get-RelativePathSafe -BasePath $BasePath -FullPath $Path
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $Path, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    }
}

function New-ZipFromPaths {
    param(
        [string[]]$Paths,
        [string]$ZipPath,
        [string]$BasePath,
        [bool]$AssumeYes = $false
    )

    if (-not (Initialize-ZipSupport)) {
        return $false
    }

    $temporaryPath = $null
    $backupPath = $null
    try {
        $parent = Split-Path -Path $ZipPath -Parent
        New-DirectoryIfMissing -Path $parent
        if (Test-Path -LiteralPath $ZipPath) {
            if (-not (Confirm-Dialog -Message ('Overwrite ZIP {0}?' -f $ZipPath) -AssumeYes $AssumeYes)) {
                return $false
            }
        }

        $temporaryPath = New-SiblingTemporaryPath -Path $ZipPath -Purpose 'zip_incoming'
        $zip = [System.IO.Compression.ZipFile]::Open($temporaryPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($path in $Paths) {
                Add-PathToZip -Zip $zip -Path $path -BasePath $BasePath
            }
        }
        finally {
            $zip.Dispose()
        }
        $testZip = [System.IO.Compression.ZipFile]::OpenRead($temporaryPath)
        try {
            [void]$testZip.Entries.Count
        }
        finally {
            $testZip.Dispose()
        }
        if (Test-Path -LiteralPath $ZipPath) {
            $backupPath = New-SiblingTemporaryPath -Path $ZipPath -Purpose 'zip_backup'
            Move-Item -LiteralPath $ZipPath -Destination $backupPath -Force -ErrorAction Stop
            Write-AppLog -Level 'WARN' -Message ('ZIP overwrite backup created: {0}' -f $backupPath)
        }
        Move-Item -LiteralPath $temporaryPath -Destination $ZipPath -Force -ErrorAction Stop
        $finalZip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            [void]$finalZip.Entries.Count
        }
        finally {
            $finalZip.Dispose()
        }
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('ZIP create failed: {0}' -f $_.Exception.Message)
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
            [void](Restore-MoveBackup -BackupPath $backupPath -Destination $ZipPath -Reason $_.Exception.Message)
        }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            try {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
            catch {
                Write-AppLog -Level 'WARN' -Message ('Temporary ZIP cleanup failed {0}: {1}' -f $temporaryPath, $_.Exception.Message)
            }
        }
        return $false
    }
}

function Expand-ZipSafe {
    param(
        [string]$ZipPath,
        [string]$DestinationPath,
        [bool]$AssumeYes = $false
    )

    if (-not (Initialize-ZipSupport)) {
        return $false
    }

    try {
        New-DirectoryIfMissing -Path $DestinationPath
        $destinationFull = [System.IO.Path]::GetFullPath($DestinationPath)
        if (-not $destinationFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $destinationFull += [System.IO.Path]::DirectorySeparatorChar
        }

        $overwritePolicy = 'Ask'
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $entryName = $entry.FullName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                if ([string]::IsNullOrWhiteSpace($entryName)) {
                    continue
                }
                $target = [System.IO.Path]::GetFullPath((Join-Path -Path $DestinationPath -ChildPath $entryName))
                if (-not $target.StartsWith($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-AppLog -Level 'WARN' -Message ('ZIP entry skipped outside destination: {0}' -f $entry.FullName)
                    continue
                }

                if ($entry.FullName.EndsWith('/')) {
                    New-DirectoryIfMissing -Path $target
                    continue
                }

                $decision = Get-OverwriteDecision -Destination $target -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $AssumeYes
                if ($decision -eq 'Cancel') {
                    return $false
                }
                if ($decision -eq 'Skip') {
                    continue
                }

                $parent = Split-Path -Path $target -Parent
                New-DirectoryIfMissing -Path $parent
                $temporaryPath = $null
                $backupPath = $null
                $inputStream = $entry.Open()
                try {
                    $temporaryPath = New-SiblingTemporaryPath -Path $target -Purpose 'zip_extract'
                    $outputStream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                    try {
                        $inputStream.CopyTo($outputStream)
                    }
                    finally {
                        $outputStream.Dispose()
                    }
                }
                finally {
                    $inputStream.Dispose()
                }
                $tempInfo = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
                if ([long]$tempInfo.Length -ne [long]$entry.Length) {
                    throw ('ZIP extract validation failed for {0}' -f $entry.FullName)
                }
                if (Test-Path -LiteralPath $target) {
                    $backupPath = New-SiblingTemporaryPath -Path $target -Purpose 'zip_extract_backup'
                    Move-Item -LiteralPath $target -Destination $backupPath -Force -ErrorAction Stop
                    Write-AppLog -Level 'WARN' -Message ('ZIP extract overwrite backup created: {0}' -f $backupPath)
                }
                try {
                    Move-Item -LiteralPath $temporaryPath -Destination $target -Force -ErrorAction Stop
                    $finalInfo = Get-Item -LiteralPath $target -Force -ErrorAction Stop
                    if ([long]$finalInfo.Length -ne [long]$entry.Length) {
                        throw ('ZIP extract final validation failed for {0}' -f $entry.FullName)
                    }
                    if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                    }
                }
                catch {
                    if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                        [void](Restore-MoveBackup -BackupPath $backupPath -Destination $target -Reason $_.Exception.Message)
                    }
                    if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
                        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    }
                    throw
                }
                [System.IO.File]::SetLastWriteTime($target, $entry.LastWriteTime.DateTime)
            }
        }
        finally {
            $zip.Dispose()
        }
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('ZIP extract failed: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Get-ZipVirtualItems {
    param(
        [string]$ZipPath
    )

    $items = @()
    if (-not (Initialize-ZipSupport)) {
        return $items
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $isDirectory = $entry.FullName.EndsWith('/')
                $name = $entry.FullName
                if ($name.EndsWith('/')) {
                    $name = $name.TrimEnd('/')
                }
                if ($name.Contains('/')) {
                    $name = $name.Substring($name.LastIndexOf('/') + 1)
                }
                if ([string]::IsNullOrWhiteSpace($name)) {
                    continue
                }
                $full = '{0}::{1}' -f $ZipPath, $entry.FullName
                $attrs = [System.IO.FileAttributes]::Archive
                if ($isDirectory) {
                    $attrs = [System.IO.FileAttributes]::Directory
                }
                $items += ,(New-FileItem -Name $entry.FullName -FullName $full -IsDirectory $isDirectory -Length $entry.Length -LastWriteTime $entry.LastWriteTime.DateTime -Attributes $attrs -IsVirtual $true -SourceProvider 'Zip')
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('ZIP browse failed: {0}' -f $_.Exception.Message)
    }

    return $items
}

function Read-TextFileSafe {
    param(
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = $null
    $encodingName = 'UTF8'
    $offset = 0

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true, $true)
        $encodingName = 'UTF8-BOM'
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.Encoding]::Unicode
        $encodingName = 'UTF16-LE'
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.Encoding]::BigEndianUnicode
        $encodingName = 'UTF16-BE'
        $offset = 2
    }
    else {
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$encoding.GetString($bytes)
            $encodingName = 'UTF8'
        }
        catch {
            $encoding = [System.Text.Encoding]::Default
            $encodingName = 'ANSI'
        }
    }

    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $lineEnding = "`r`n"
    if ($text.Contains("`r`n")) {
        $lineEnding = "`r`n"
    }
    elseif ($text.Contains("`n")) {
        $lineEnding = "`n"
    }
    elseif ($text.Contains("`r")) {
        $lineEnding = "`r"
    }

    return @{
        Text = $text
        Encoding = $encoding
        EncodingName = $encodingName
        LineEnding = $lineEnding
    }
}

function Test-BinaryFile {
    param(
        [string]$Path
    )

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] ([Math]::Min(4096, [int]$stream.Length))
            $read = $stream.Read($buffer, 0, $buffer.Length)
            for ($i = 0; $i -lt $read; $i++) {
                if ($buffer[$i] -eq 0) {
                    return $true
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $true
    }
    return $false
}

function Convert-BytesToHexLines {
    param(
        [byte[]]$Bytes
    )

    $lines = @()
    for ($offset = 0; $offset -lt $Bytes.Length; $offset += 16) {
        $count = [Math]::Min(16, $Bytes.Length - $offset)
        $hexParts = @()
        $ascii = ''
        for ($i = 0; $i -lt $count; $i++) {
            $value = $Bytes[$offset + $i]
            $hexParts += $value.ToString('X2')
            if ($value -ge 32 -and $value -le 126) {
                $ascii += [char]$value
            }
            else {
                $ascii += '.'
            }
        }
        $lines += ('{0:X8}  {1,-47}  {2}' -f $offset, ([string]::Join(' ', $hexParts)), $ascii)
    }
    return $lines
}

function Read-FilePrefixBytes {
    param(
        [string]$Path,
        [int]$MaxBytes
    )

    if ($MaxBytes -lt 1) {
        return (New-Object byte[] 0)
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $lengthToRead = [Math]::Min([int64]$MaxBytes, $stream.Length)
        $buffer = New-Object byte[] ([int]$lengthToRead)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -le 0) {
                break
            }
            $offset += $read
        }
        if ($offset -eq $buffer.Length) {
            return $buffer
        }
        $small = New-Object byte[] $offset
        [Array]::Copy($buffer, $small, $offset)
        return $small
    }
    finally {
        $stream.Dispose()
    }
}

function Read-TextPrefixLines {
    param(
        [string]$Path,
        [int]$MaxBytes
    )

    $bytes = Read-FilePrefixBytes -Path $Path -MaxBytes $MaxBytes
    if ($bytes.Length -eq 0) {
        return @('')
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $false)
    $text = $encoding.GetString($bytes)
    return [System.Text.RegularExpressions.Regex]::Split($text, "\r\n|\n|\r")
}

function Show-TextViewer {
    param(
        [string[]]$Lines,
        [string]$Title = 'Viewer'
    )

    $top = 0
    $wrap = $false
    $search = ''
    while ($true) {
        $size = Get-ConsoleSizeSafe
        $width = $size.Width
        $height = $size.Height
        $bodyHeight = $height - 2
        Write-At -Left 0 -Top 0 -Text (' {0} | Lines {1} | Ctrl+F find | F3 next | W wrap | Esc/F10 quit ' -f $Title, $Lines.Count) -Width $width -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)
        for ($i = 0; $i -lt $bodyHeight; $i++) {
            $lineIndex = $top + $i
            $text = ''
            if ($lineIndex -lt $Lines.Count) {
                $text = $Lines[$lineIndex]
                if (-not $wrap) {
                    $text = Truncate-Text -Text $text -Width $width
                }
            }
            Write-At -Left 0 -Top ($i + 1) -Text $text -Width $width -Foreground ([ConsoleColor]::Gray) -Background ([ConsoleColor]::Black)
        }
        $status = ('Line {0}/{1}' -f ([Math]::Min($top + 1, $Lines.Count)), $Lines.Count)
        Write-At -Left 0 -Top ($height - 1) -Text $status -Width $width -Foreground ([ConsoleColor]::Black) -Background ([ConsoleColor]::Gray)

        $key = Read-KeyEventOnly
        if ($key.Key -eq [ConsoleKey]::Escape -or $key.Key -eq [ConsoleKey]::F10) {
            break
        }
        switch ($key.Key) {
            ([ConsoleKey]::UpArrow) { if ($top -gt 0) { $top-- } }
            ([ConsoleKey]::DownArrow) { if ($top -lt ($Lines.Count - 1)) { $top++ } }
            ([ConsoleKey]::PageUp) { $top = [Math]::Max(0, $top - $bodyHeight) }
            ([ConsoleKey]::PageDown) { $top = [Math]::Min([Math]::Max(0, $Lines.Count - 1), $top + $bodyHeight) }
            ([ConsoleKey]::Home) { $top = 0 }
            ([ConsoleKey]::End) { $top = [Math]::Max(0, $Lines.Count - 1) }
            ([ConsoleKey]::W) { $wrap = -not $wrap }
            ([ConsoleKey]::F3) {
                if (-not [string]::IsNullOrWhiteSpace($search)) {
                    for ($i = $top + 1; $i -lt $Lines.Count; $i++) {
                        if ($Lines[$i].IndexOf($search, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $top = $i
                            break
                        }
                    }
                }
            }
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0 -and $key.Key -eq [ConsoleKey]::F) {
            $search = Read-DialogLine -Prompt 'Find' -Default $search
            if ($null -ne $search -and -not [string]::IsNullOrWhiteSpace($search)) {
                for ($i = 0; $i -lt $Lines.Count; $i++) {
                    if ($Lines[$i].IndexOf($search, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $top = $i
                        break
                    }
                }
            }
        }
    }
    Request-FullRedraw
}

function Show-FileViewer {
    param(
        [string]$Path
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (Test-BinaryFile -Path $Path) {
            $maxBytes = 1048576
            $bytes = Read-FilePrefixBytes -Path $Path -MaxBytes $maxBytes
            $truncated = ($item.Length -gt $bytes.Length)
            $lines = Convert-BytesToHexLines -Bytes $bytes
            $lines = @(
                ('File size: {0} bytes' -f $item.Length),
                ('Bytes displayed: {0}' -f $bytes.Length),
                ('Truncated: {0}' -f $truncated),
                ''
            ) + $lines
            Show-TextViewer -Lines $lines -Title ('Hex: {0}' -f $item.Name)
            return
        }

        if ($item.Length -gt 10485760) {
            if (-not (Confirm-Dialog -Message 'Large text file. Load first 1 MB preview?' -DefaultYes $false)) {
                return
            }
            $lines = Read-TextPrefixLines -Path $Path -MaxBytes 1048576
            $lines = @(
                ('File size: {0} bytes' -f $item.Length),
                'Bytes displayed: 1048576 or less',
                'Truncated: True',
                ''
            ) + $lines
            Show-TextViewer -Lines $lines -Title ('Preview: {0}' -f $item.Name)
            return
        }

        $textInfo = Read-TextFileSafe -Path $Path
        $lines = @()
        if ([string]::IsNullOrEmpty($textInfo.Text)) {
            $lines = @('')
        }
        else {
            $lines = [System.Text.RegularExpressions.Regex]::Split($textInfo.Text, "\r\n|\n|\r")
        }
        Show-TextViewer -Lines $lines -Title ('View: {0} ({1})' -f $item.Name, $textInfo.EncodingName)
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Viewer failed {0}: {1}' -f $Path, $_.Exception.Message)
        Show-Message -Message ('Cannot view file: {0}' -f $_.Exception.Message)
    }
}

function Save-EditorFile {
    param(
        [string]$Path,
        [System.Collections.ArrayList]$Lines,
        [System.Text.Encoding]$Encoding,
        [string]$LineEnding
    )

    try {
        $text = [string]::Join($LineEnding, [string[]]$Lines.ToArray([string]))
        [System.IO.File]::WriteAllText($Path, $text, $Encoding)
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Editor save failed {0}: {1}' -f $Path, $_.Exception.Message)
        return $false
    }
}

# English: Insert text into the simple editor, preserving multi-line clipboard content.
# Magyar: Szoveg beszurasa az egyszeru editorba, tobbsoros clipboard tartalommal is.
function Insert-EditorText {
    param(
        [System.Collections.ArrayList]$Lines,
        [int]$CursorLine,
        [int]$CursorColumn,
        [string]$Text
    )

    if ($null -eq $Text) {
        $Text = ''
    }
    if ($Lines.Count -eq 0) {
        [void]$Lines.Add('')
    }

    $parts = [System.Text.RegularExpressions.Regex]::Split($Text, "\r\n|\n|\r")
    $line = [string]$Lines[$CursorLine]
    $before = $line.Substring(0, $CursorColumn)
    $after = $line.Substring($CursorColumn)

    if ($parts.Count -le 1) {
        $Lines[$CursorLine] = $before + $Text + $after
        return @{ Line = $CursorLine; Column = $CursorColumn + $Text.Length }
    }

    $Lines[$CursorLine] = $before + [string]$parts[0]
    $insertLine = $CursorLine + 1
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $value = [string]$parts[$i]
        if ($i -eq ($parts.Count - 1)) {
            $value += $after
        }
        $Lines.Insert($insertLine, $value)
        $insertLine++
    }

    return @{ Line = $CursorLine + $parts.Count - 1; Column = ([string]$parts[$parts.Count - 1]).Length }
}

# English: Keep Tab insertion small and configurable without adding a full editor model.
# Magyar: A Tab beszuras kicsi es konfiguralhato marad teljes editor modell nelkul.
function Get-EditorTabText {
    $tabSize = [int]$script:Config.EditorTabSize
    if ($tabSize -lt 1) { $tabSize = 4 }
    if ($tabSize -gt 16) { $tabSize = 16 }
    return (' ' * $tabSize)
}

function Show-FileEditor {
    param(
        [string]$Path
    )

    $lines = New-Object System.Collections.ArrayList
    $encoding = Get-DefaultTextEncodingObject
    $lineEnding = "`r`n"
    $dirty = $false
    $existing = Test-Path -LiteralPath $Path -PathType Leaf

    try {
        if ($existing) {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.Length -gt 5242880) {
                if (-not (Confirm-Dialog -Message 'Large file. Edit anyway?' -DefaultYes $false)) {
                    return
                }
            }
            if (Test-BinaryFile -Path $Path) {
                Show-Message -Message 'Binary file editing is blocked.'
                return
            }
            $textInfo = Read-TextFileSafe -Path $Path
            $encoding = $textInfo.Encoding
            $lineEnding = $textInfo.LineEnding
            $splitLines = [System.Text.RegularExpressions.Regex]::Split($textInfo.Text, "\r\n|\n|\r")
            foreach ($line in $splitLines) {
                [void]$lines.Add($line)
            }
            if ($lines.Count -eq 0) {
                [void]$lines.Add('')
            }
        }
        else {
            [void]$lines.Add('')
            $dirty = $true
        }
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Editor open failed {0}: {1}' -f $Path, $_.Exception.Message)
        Show-Message -Message ('Cannot edit file: {0}' -f $_.Exception.Message)
        return
    }

    $cursorLine = 0
    $cursorColumn = 0
    $topLine = 0
    $leftColumn = 0
    $findText = ''

    while ($true) {
        $size = Get-ConsoleSizeSafe
        $width = $size.Width
        $height = $size.Height
        $bodyHeight = $height - 2
        $dirtyMark = ' '
        if ($dirty) { $dirtyMark = '*' }
        Write-At -Left 0 -Top 0 -Text ('{0} Edit: {1} | Ctrl+S save Ctrl+Q quit Ctrl+F find F3 next Ctrl+G line' -f $dirtyMark, $Path) -Width $width -Foreground ([ConsoleColor]::White) -Background ([ConsoleColor]::DarkBlue)

        if ($cursorLine -lt $topLine) {
            $topLine = $cursorLine
        }
        if ($cursorLine -ge ($topLine + $bodyHeight)) {
            $topLine = [Math]::Max(0, $cursorLine - $bodyHeight + 1)
        }
        if ($cursorColumn -lt $leftColumn) {
            $leftColumn = $cursorColumn
        }
        if ($cursorColumn -ge ($leftColumn + $width)) {
            $leftColumn = [Math]::Max(0, $cursorColumn - $width + 1)
        }

        for ($i = 0; $i -lt $bodyHeight; $i++) {
            $lineIndex = $topLine + $i
            $text = ''
            if ($lineIndex -lt $lines.Count) {
                $text = [string]$lines[$lineIndex]
                if ($leftColumn -lt $text.Length) {
                    $text = $text.Substring($leftColumn)
                }
                else {
                    $text = ''
                }
            }
            Write-At -Left 0 -Top ($i + 1) -Text $text -Width $width -Foreground ([ConsoleColor]::Gray) -Background ([ConsoleColor]::Black)
        }

        $status = ('Line {0}/{1} Col {2}' -f ($cursorLine + 1), $lines.Count, ($cursorColumn + 1))
        Write-At -Left 0 -Top ($height - 1) -Text $status -Width $width -Foreground ([ConsoleColor]::Black) -Background ([ConsoleColor]::Gray)
        try {
            [Console]::CursorVisible = $true
            [Console]::SetCursorPosition([Math]::Max(0, $cursorColumn - $leftColumn), [Math]::Max(1, $cursorLine - $topLine + 1))
        }
        catch {
        }

        $key = Read-KeyEventOnly
        $control = (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)

        if ($key.Key -eq [ConsoleKey]::F10 -or ($control -and $key.Key -eq [ConsoleKey]::Q) -or $key.Key -eq [ConsoleKey]::Escape) {
            if ($dirty) {
                if (-not (Confirm-Dialog -Message 'Unsaved changes. Quit editor?' -DefaultYes $false)) {
                    continue
                }
            }
            break
        }

        if ($control -and $key.Key -eq [ConsoleKey]::S) {
            if (Save-EditorFile -Path $Path -Lines $lines -Encoding $encoding -LineEnding $lineEnding) {
                $dirty = $false
            }
            else {
                Show-Message -Message 'Save failed. See log.'
            }
            continue
        }

        if ($control -and $key.Key -eq [ConsoleKey]::A) {
            $script:InternalClipboard = @()
            foreach ($line in $lines) {
                $script:InternalClipboard += [string]$line
            }
            Show-Message -Message 'All editor text copied to internal clipboard.'
            continue
        }

        if ($control -and $key.Key -eq [ConsoleKey]::V) {
            try {
                $clipText = Get-Clipboard -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrEmpty($clipText)) {
                    $position = Insert-EditorText -Lines $lines -CursorLine $cursorLine -CursorColumn $cursorColumn -Text $clipText
                    $cursorLine = [int]$position.Line
                    $cursorColumn = [int]$position.Column
                    $dirty = $true
                }
            }
            catch {
                Write-AppLog -Level 'WARN' -Message ('Editor clipboard paste failed: {0}' -f $_.Exception.Message)
                Show-Message -Message 'Clipboard paste failed.'
            }
            continue
        }

        if ($control -and $key.Key -eq [ConsoleKey]::F) {
            $findText = Read-DialogLine -Prompt 'Find' -Default $findText
            if (-not [string]::IsNullOrWhiteSpace($findText)) {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $pos = ([string]$lines[$i]).IndexOf($findText, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($pos -ge 0) {
                        $cursorLine = $i
                        $cursorColumn = $pos
                        break
                    }
                }
            }
            continue
        }

        if ($key.Key -eq [ConsoleKey]::F3 -and -not [string]::IsNullOrWhiteSpace($findText)) {
            $found = $false
            for ($i = $cursorLine; $i -lt $lines.Count; $i++) {
                $start = 0
                if ($i -eq $cursorLine) { $start = $cursorColumn + 1 }
                $pos = ([string]$lines[$i]).IndexOf($findText, $start, [System.StringComparison]::OrdinalIgnoreCase)
                if ($pos -ge 0) {
                    $cursorLine = $i
                    $cursorColumn = $pos
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                Show-Message -Message 'No next match.'
            }
            continue
        }

        if ($control -and $key.Key -eq [ConsoleKey]::G) {
            $lineText = Read-DialogLine -Prompt 'Go to line' -Default ([string]($cursorLine + 1))
            $lineNumber = 0
            if ([int]::TryParse($lineText, [ref]$lineNumber)) {
                $cursorLine = [Math]::Max(0, [Math]::Min($lines.Count - 1, $lineNumber - 1))
                $cursorColumn = [Math]::Min($cursorColumn, ([string]$lines[$cursorLine]).Length)
            }
            continue
        }

        switch ($key.Key) {
            ([ConsoleKey]::LeftArrow) {
                if ($cursorColumn -gt 0) { $cursorColumn-- }
                elseif ($cursorLine -gt 0) {
                    $cursorLine--
                    $cursorColumn = ([string]$lines[$cursorLine]).Length
                }
            }
            ([ConsoleKey]::RightArrow) {
                if ($cursorColumn -lt ([string]$lines[$cursorLine]).Length) { $cursorColumn++ }
                elseif ($cursorLine -lt ($lines.Count - 1)) {
                    $cursorLine++
                    $cursorColumn = 0
                }
            }
            ([ConsoleKey]::UpArrow) {
                if ($cursorLine -gt 0) {
                    $cursorLine--
                    $cursorColumn = [Math]::Min($cursorColumn, ([string]$lines[$cursorLine]).Length)
                }
            }
            ([ConsoleKey]::DownArrow) {
                if ($cursorLine -lt ($lines.Count - 1)) {
                    $cursorLine++
                    $cursorColumn = [Math]::Min($cursorColumn, ([string]$lines[$cursorLine]).Length)
                }
            }
            ([ConsoleKey]::Home) { $cursorColumn = 0 }
            ([ConsoleKey]::End) { $cursorColumn = ([string]$lines[$cursorLine]).Length }
            ([ConsoleKey]::PageUp) {
                $cursorLine = [Math]::Max(0, $cursorLine - $bodyHeight)
                $cursorColumn = [Math]::Min($cursorColumn, ([string]$lines[$cursorLine]).Length)
            }
            ([ConsoleKey]::PageDown) {
                $cursorLine = [Math]::Min($lines.Count - 1, $cursorLine + $bodyHeight)
                $cursorColumn = [Math]::Min($cursorColumn, ([string]$lines[$cursorLine]).Length)
            }
            ([ConsoleKey]::Backspace) {
                if ($cursorColumn -gt 0) {
                    $line = [string]$lines[$cursorLine]
                    $lines[$cursorLine] = $line.Remove($cursorColumn - 1, 1)
                    $cursorColumn--
                    $dirty = $true
                }
                elseif ($cursorLine -gt 0) {
                    $previous = [string]$lines[$cursorLine - 1]
                    $current = [string]$lines[$cursorLine]
                    $cursorColumn = $previous.Length
                    $lines[$cursorLine - 1] = $previous + $current
                    $lines.RemoveAt($cursorLine)
                    $cursorLine--
                    $dirty = $true
                }
            }
            ([ConsoleKey]::Delete) {
                $line = [string]$lines[$cursorLine]
                if ($cursorColumn -lt $line.Length) {
                    $lines[$cursorLine] = $line.Remove($cursorColumn, 1)
                    $dirty = $true
                }
                elseif ($cursorLine -lt ($lines.Count - 1)) {
                    $lines[$cursorLine] = $line + [string]$lines[$cursorLine + 1]
                    $lines.RemoveAt($cursorLine + 1)
                    $dirty = $true
                }
            }
            ([ConsoleKey]::Enter) {
                $line = [string]$lines[$cursorLine]
                $before = $line.Substring(0, $cursorColumn)
                $after = $line.Substring($cursorColumn)
                $lines[$cursorLine] = $before
                $lines.Insert($cursorLine + 1, $after)
                $cursorLine++
                $cursorColumn = 0
                $dirty = $true
            }
            ([ConsoleKey]::Tab) {
                $spaces = Get-EditorTabText
                $line = [string]$lines[$cursorLine]
                $lines[$cursorLine] = $line.Insert($cursorColumn, $spaces)
                $cursorColumn += $spaces.Length
                $dirty = $true
            }
            default {
                if (-not $control -and -not [char]::IsControl($key.KeyChar)) {
                    $line = [string]$lines[$cursorLine]
                    $lines[$cursorLine] = $line.Insert($cursorColumn, [string]$key.KeyChar)
                    $cursorColumn++
                    $dirty = $true
                }
            }
        }
    }
    try { [Console]::CursorVisible = $false } catch {}
    Request-FullRedraw
}

function Search-FilesInternal {
    param(
        [string]$StartPath,
        [string]$NamePattern,
        [bool]$NameRegex = $false,
        [string]$ContentPattern = '',
        [bool]$ContentRegex = $false,
        [bool]$CaseSensitive = $false,
        [bool]$WholeWord = $false
    )

    $results = @()
    $ignoreNames = @('.git', '.svn', 'node_modules', 'bin', 'obj')
    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::None
    if (-not $CaseSensitive) {
        $regexOptions = $regexOptions -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-NormalizedPath -Path $StartPath))

    while ($stack.Count -gt 0) {
        $currentPath = [string]$stack.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop)
        }
        catch {
            Write-AppLog -Level 'WARN' -Message ('Search cannot read {0}: {1}' -f $currentPath, $_.Exception.Message)
            continue
        }

        foreach ($child in $children) {
            $isDirectory = (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            if ($isDirectory) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    continue
                }
                if ($ignoreNames -contains $child.Name) {
                    continue
                }
                $stack.Push($child.FullName)
            }

            $nameMatches = $true
            if (-not [string]::IsNullOrWhiteSpace($NamePattern)) {
                if ($NameRegex) {
                    try {
                        $nameMatches = [System.Text.RegularExpressions.Regex]::IsMatch($child.Name, $NamePattern, $regexOptions)
                    }
                    catch {
                        $nameMatches = $false
                    }
                }
                else {
                    if ($CaseSensitive) {
                        $nameMatches = ($child.Name -clike $NamePattern)
                    }
                    else {
                        $nameMatches = ($child.Name -like $NamePattern)
                    }
                }
            }

            if (-not $nameMatches) {
                continue
            }

            $contentMatches = $true
            if (-not $isDirectory -and -not [string]::IsNullOrWhiteSpace($ContentPattern)) {
                $contentMatches = $false
                try {
                    if (-not (Test-BinaryFile -Path $child.FullName)) {
                        $reader = [System.IO.File]::OpenText($child.FullName)
                        try {
                            while (-not $reader.EndOfStream) {
                                $line = $reader.ReadLine()
                                if ($ContentRegex -or $WholeWord) {
                                    $pattern = $ContentPattern
                                    if (-not $ContentRegex) {
                                        $pattern = [System.Text.RegularExpressions.Regex]::Escape($ContentPattern)
                                    }
                                    if ($WholeWord) {
                                        $pattern = '\b' + $pattern + '\b'
                                    }
                                    if ([System.Text.RegularExpressions.Regex]::IsMatch($line, $pattern, $regexOptions)) {
                                        $contentMatches = $true
                                        break
                                    }
                                }
                                else {
                                    $comparison = [System.StringComparison]::OrdinalIgnoreCase
                                    if ($CaseSensitive) {
                                        $comparison = [System.StringComparison]::Ordinal
                                    }
                                    if ($line.IndexOf($ContentPattern, $comparison) -ge 0) {
                                        $contentMatches = $true
                                        break
                                    }
                                }
                            }
                        }
                        finally {
                            $reader.Dispose()
                        }
                    }
                }
                catch {
                    Write-AppLog -Level 'WARN' -Message ('Content search skipped {0}: {1}' -f $child.FullName, $_.Exception.Message)
                }
            }

            if ($contentMatches) {
                $length = 0
                if (-not $isDirectory) { $length = [long]$child.Length }
                $results += ,(New-FileItem -Name $child.FullName -FullName $child.FullName -IsDirectory $isDirectory -Length $length -LastWriteTime $child.LastWriteTime -Attributes $child.Attributes -IsVirtual $true -SourceProvider 'SearchResults')
            }
        }
    }

    return $results
}

function Invoke-SearchDialog {
    $panel = Get-ActivePanel
    $startPath = $panel.Path
    if ($panel.Provider -ne 'Local') {
        $startPath = $panel.ReturnPath
    }
    $namePattern = Read-DialogLine -Prompt 'Find name wildcard (prefix r: for regex)' -Default '*'
    if ($null -eq $namePattern) { return }
    $nameRegex = $false
    if ($namePattern.StartsWith('r:')) {
        $nameRegex = $true
        $namePattern = $namePattern.Substring(2)
    }
    $content = Read-DialogLine -Prompt 'Content search (empty for none)' -Default ''
    if ($null -eq $content) { $content = '' }
    # English: Content search supports the same regex and whole-word engine used by self-test.
    # Magyar: A tartalomkereses a self-test altal is hasznalt regex es whole-word motort eri el.
    $contentRegex = $false
    $wholeWord = $false
    if ($content.StartsWith('r:')) {
        $contentRegex = $true
        $content = $content.Substring(2)
    }
    if (-not [string]::IsNullOrWhiteSpace($content)) {
        $wholeWordIndex = Show-MenuList -Title 'Content match mode' -Items @('Substring match', 'Whole word match')
        if ($wholeWordIndex -lt 0) { return }
        $wholeWord = ($wholeWordIndex -eq 1)
    }
    $results = Search-FilesInternal -StartPath $startPath -NamePattern $namePattern -NameRegex $nameRegex -ContentPattern $content -ContentRegex $contentRegex -WholeWord $wholeWord -CaseSensitive ([bool]$script:Config.CaseSensitiveSearch)
    Set-PanelVirtualItems -Panel $panel -Provider 'SearchResults' -Title ('Search: {0}' -f $namePattern) -Items $results -ReturnPath $startPath
}

function Invoke-QuickSearch {
    $panel = Get-ActivePanel
    $text = Read-DialogLine -Prompt 'Quick search' -Default ''
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    for ($i = 0; $i -lt $panel.Items.Count; $i++) {
        if ($panel.Items[$i].Name.IndexOf($text, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Set-SelectionAbsolute -Panel $panel -Index $i -VisibleRows $script:State.VisibleRows
            return
        }
    }
    Show-Message -Message 'No match.'
}

function Stop-ProcessTreeSafe {
    param(
        [int]$ProcessId
    )

    try {
        $children = @(Get-WmiObject -Class Win32_Process -Filter ("ParentProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            Stop-ProcessTreeSafe -ProcessId ([int]$child.ProcessId)
        }
        $target = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        if (-not $target.HasExited) {
            $target.Kill()
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ('Process tree kill skipped for {0}: {1}' -f $ProcessId, $_.Exception.Message)
    }
}

function Invoke-CommandLineSafe {
    param(
        [string]$CommandLine,
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return @()
    }

    if ($CommandLine -match '(?i)^\s*(powershell(\.exe)?|pwsh(\.exe)?|cmd(\.exe)?)\s*$' -or $CommandLine -match '(?i)\s-NoExit(\s|$)') {
        Write-AppLog -Level 'WARN' -Message ('Interactive command refused under redirected execution: {0}' -f $CommandLine)
        return @(
            'Command refused.',
            'Interactive shells are not run through redirected command output.',
            'Use F2 -> Open PowerShell here for an interactive shell.'
        )
    }

    try {
        $timeoutSeconds = [int]$script:Config.CommandTimeoutSeconds
        if ($timeoutSeconds -lt 1) {
            $timeoutSeconds = 60
        }
        if (-not $script:NonInteractiveMode) {
            Show-ProgressDialog -Operation 'Command' -CurrentItem $CommandLine -Index 1 -Total 1
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-UsableBasePath -Preferred $env:ComSpec -Fallback 'cmd.exe')
        $psi.Arguments = '/d /c ' + $CommandLine
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        foreach ($key in $Environment.Keys) {
            if ($null -ne $Environment[$key]) {
                $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
            }
        }
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $finished) {
            Stop-ProcessTreeSafe -ProcessId $process.Id
            return @(
                ('Command timed out after {0} seconds.' -f $timeoutSeconds),
                ('Command: {0}' -f $CommandLine)
            )
        }
        $outputTask.Wait()
        $errorTask.Wait()
        $output = $outputTask.Result
        $errorOutput = $errorTask.Result
        $lines = @()
        $lines += ('Command: {0}' -f $CommandLine)
        $lines += ('Exit code: {0}' -f $process.ExitCode)
        $lines += ''
        if (-not [string]::IsNullOrEmpty($output)) {
            $lines += [System.Text.RegularExpressions.Regex]::Split($output.TrimEnd(), "\r\n|\n|\r")
        }
        if (-not [string]::IsNullOrEmpty($errorOutput)) {
            $lines += ''
            $lines += 'stderr:'
            $lines += [System.Text.RegularExpressions.Regex]::Split($errorOutput.TrimEnd(), "\r\n|\n|\r")
        }
        return $lines
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Command failed {0}: {1}' -f $CommandLine, $_.Exception.Message)
        return @('Command failed:', $_.Exception.Message)
    }
}

function Invoke-InteractiveShellHere {
    $panel = Get-ActivePanel
    $workingDirectory = $panel.Path
    if ([string]::IsNullOrWhiteSpace($workingDirectory) -or -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        $workingDirectory = (Get-Location).ProviderPath
    }

    try {
        Restore-ConsoleInputMode
        Reset-ConsoleColorsSafe
        Clear-ScreenSafe
        Write-Host 'Leaving console_commander temporarily. Type exit to return.'
        Write-Host ('Directory: {0}' -f $workingDirectory)
        Push-Location -LiteralPath $workingDirectory
        try {
            & powershell.exe -NoProfile
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Interactive shell failed: {0}' -f $_.Exception.Message)
        Show-Message -Message ('Shell failed: {0}' -f $_.Exception.Message)
    }
    finally {
        Initialize-ConsoleInputMode
        Request-FullRedraw
    }
}

function Quote-CmdArgument {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }
    $escaped = $Value.Replace('^', '^^')
    $escaped = $escaped.Replace('&', '^&')
    $escaped = $escaped.Replace('|', '^|')
    $escaped = $escaped.Replace('<', '^<')
    $escaped = $escaped.Replace('>', '^>')
    $escaped = $escaped.Replace('(', '^(')
    $escaped = $escaped.Replace(')', '^)')
    $escaped = $escaped.Replace('%', '^%')
    $escaped = $escaped.Replace('!', '^!')
    $escaped = $escaped.Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Quote-PowerShellSingleQuotedString {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Expand-CommandMacros {
    param(
        [string]$Command,
        [object[]]$Items
    )

    $active = Get-ActivePanel
    $passive = Get-PassivePanel
    $current = Get-CurrentItem -Panel $active
    $selectedName = ''
    $selectedPath = ''
    if ($null -ne $current) {
        $selectedName = $current.Name
        $selectedPath = $current.FullName
    }
    $selectedPaths = @()
    foreach ($item in $Items) {
        $selectedPaths += $item.FullName
    }
    $script:LastCommandMacroEnvironment = @{
        CC_SELECTED_NAME = $selectedName
        CC_SELECTED_PATH = $selectedPath
        CC_ACTIVE_DIR = $active.Path
        CC_PASSIVE_DIR = $passive.Path
        CC_SELECTED_PATHS = [string]::Join(';', [string[]]$selectedPaths)
    }

    $expanded = $Command
    $expanded = $expanded.Replace('%f', (Quote-CmdArgument -Value $selectedName))
    $expanded = $expanded.Replace('%p', (Quote-CmdArgument -Value $selectedPath))
    $expanded = $expanded.Replace('%d', (Quote-CmdArgument -Value $active.Path))
    $expanded = $expanded.Replace('%D', (Quote-CmdArgument -Value $passive.Path))
    $quotedPaths = @()
    foreach ($path in $selectedPaths) {
        $quotedPaths += (Quote-CmdArgument -Value $path)
    }
    $expanded = $expanded.Replace('%s', ([string]::Join(' ', [string[]]$quotedPaths)))
    return $expanded
}

function Invoke-ExternalPanelize {
    $panel = Get-ActivePanel
    $command = Read-DialogLine -Prompt 'Panelize command' -Default ''
    if ([string]::IsNullOrWhiteSpace($command)) {
        return
    }
    $script:Config.PanelizeCommands += $command
    [void](Save-AppConfig)
    $lines = Invoke-CommandLineSafe -CommandLine $command -WorkingDirectory $panel.Path
    $items = @()
    $textLines = @()
    foreach ($line in $lines) {
        $candidate = $line.Trim()
        if (Test-Path -LiteralPath $candidate) {
            try {
                $child = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
                $isDirectory = (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
                $length = 0
                if (-not $isDirectory) { $length = [long]$child.Length }
                $items += ,(New-FileItem -Name $child.FullName -FullName $child.FullName -IsDirectory $isDirectory -Length $length -LastWriteTime $child.LastWriteTime -Attributes $child.Attributes -IsVirtual $true -SourceProvider 'PanelizeResults')
            }
            catch {
                $textLines += $line
            }
        }
        else {
            $textLines += $line
        }
    }

    if ($items.Count -gt 0) {
        Set-PanelVirtualItems -Panel $panel -Provider 'PanelizeResults' -Title 'Panelized command' -Items $items -ReturnPath $panel.Path
    }
    else {
        Show-TextViewer -Lines $textLines -Title 'Command results'
    }
}

function Show-Properties {
    param(
        [string]$Path
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $lines = @()
        $lines += ('Path: {0}' -f $item.FullName)
        $lines += ('Name: {0}' -f $item.Name)
        $lines += ('Type: {0}' -f $item.GetType().FullName)
        $lines += ('Attributes: {0}' -f $item.Attributes)
        $lines += ('Created: {0}' -f $item.CreationTime)
        $lines += ('Modified: {0}' -f $item.LastWriteTime)
        $lines += ('Accessed: {0}' -f $item.LastAccessTime)
        if ($item.PSIsContainer -eq $false) {
            $lines += ('Length: {0}' -f $item.Length)
        }
        try {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $lines += ''
            $lines += ('Owner: {0}' -f $acl.Owner)
            $lines += 'ACL:'
            foreach ($rule in $acl.Access) {
                $lines += ('  {0} {1} {2} {3}' -f $rule.IdentityReference, $rule.FileSystemRights, $rule.AccessControlType, $rule.IsInherited)
            }
        }
        catch {
            $lines += ('ACL unavailable: {0}' -f $_.Exception.Message)
        }
        Show-TextViewer -Lines $lines -Title 'Properties'
    }
    catch {
        Show-Message -Message ('Cannot show properties: {0}' -f $_.Exception.Message)
    }
}

function Toggle-Attribute {
    param(
        [string]$Path,
        [System.IO.FileAttributes]$Attribute
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band $Attribute) -ne 0) {
            $item.Attributes = $item.Attributes -band (-bnot $Attribute)
        }
        else {
            $item.Attributes = $item.Attributes -bor $Attribute
        }
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Attribute toggle failed {0}: {1}' -f $Path, $_.Exception.Message)
        Show-Message -Message ('Cannot change attribute: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Show-DiffViewer {
    $active = Get-ActivePanel
    $passive = Get-PassivePanel
    $left = Get-CurrentItem -Panel $active
    $right = Get-CurrentItem -Panel $passive

    if ($null -eq $left -or $null -eq $right -or $left.IsDirectory -or $right.IsDirectory) {
        Show-Message -Message 'Select one file in each panel.'
        return
    }

    try {
        if ((Test-BinaryFile -Path $left.FullName) -or (Test-BinaryFile -Path $right.FullName)) {
            Show-Message -Message 'Binary diff is not supported.'
            return
        }

        $leftText = Read-TextFileSafe -Path $left.FullName
        $rightText = Read-TextFileSafe -Path $right.FullName
        $leftLines = [System.Text.RegularExpressions.Regex]::Split($leftText.Text, "\r\n|\n|\r")
        $rightLines = [System.Text.RegularExpressions.Regex]::Split($rightText.Text, "\r\n|\n|\r")
        $max = [Math]::Max($leftLines.Count, $rightLines.Count)
        $diff = @()
        $diff += ('--- {0}' -f $left.FullName)
        $diff += ('+++ {0}' -f $right.FullName)
        for ($i = 0; $i -lt $max; $i++) {
            $leftLine = ''
            $rightLine = ''
            if ($i -lt $leftLines.Count) { $leftLine = $leftLines[$i] }
            if ($i -lt $rightLines.Count) { $rightLine = $rightLines[$i] }
            if ($leftLine -ne $rightLine) {
                $diff += ('@@ line {0} @@' -f ($i + 1))
                if ($i -lt $leftLines.Count) { $diff += ('- {0,6}: {1}' -f ($i + 1), $leftLine) }
                if ($i -lt $rightLines.Count) { $diff += ('+ {0,6}: {1}' -f ($i + 1), $rightLine) }
            }
        }
        if ($diff.Count -eq 2) {
            $diff += 'Files are identical.'
        }
        Show-TextViewer -Lines $diff -Title 'Diff'
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Diff failed: {0}' -f $_.Exception.Message)
        Show-Message -Message ('Diff failed: {0}' -f $_.Exception.Message)
    }
}

function Get-FileHashSafe {
    param(
        [string]$Path
    )

    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            try {
                $hashBytes = $sha.ComputeHash($stream)
                return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $stream.Dispose()
            }
        }
        finally {
            $sha.Dispose()
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ('Hash failed {0}: {1}' -f $Path, $_.Exception.Message)
        return ''
    }
}

function Get-DirectoryCompareMap {
    param(
        [string]$RootPath,
        [bool]$Recursive
    )

    $map = @{}
    if ($Recursive) {
        $files = @(Get-ChildItem -LiteralPath $RootPath -File -Recurse -Force -ErrorAction SilentlyContinue)
    }
    else {
        $files = @(Get-ChildItem -LiteralPath $RootPath -File -Force -ErrorAction SilentlyContinue)
    }
    foreach ($file in $files) {
        try {
            $relative = Get-RelativePathSafe -BasePath $RootPath -FullPath $file.FullName
            $map[$relative.ToLowerInvariant()] = $file
        }
        catch {
            Write-AppLog -Level 'WARN' -Message ('Directory compare skipped {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
    }
    return $map
}

function Compare-Directories {
    $active = Get-ActivePanel
    $passive = Get-PassivePanel
    if ($active.Provider -ne 'Local' -or $passive.Provider -ne 'Local') {
        Show-Message -Message 'Directory compare requires local panels.'
        return
    }

    $scopeIndex = Show-MenuList -Title 'Directory compare scope' -Items @('Top-level one-way active vs passive', 'Top-level two-way', 'Recursive one-way active vs passive', 'Recursive two-way')
    if ($scopeIndex -lt 0) { return }
    $modeIndex = Show-MenuList -Title 'Directory compare mode' -Items @('Size only', 'Size + modified time', 'SHA256 hash')
    if ($modeIndex -lt 0) { return }
    $recursive = ($scopeIndex -ge 2)
    $twoWay = ($scopeIndex -eq 1 -or $scopeIndex -eq 3)

    try {
        $active.Marks = @{}
        $passive.Marks = @{}
        $activeMap = Get-DirectoryCompareMap -RootPath $active.Path -Recursive $recursive
        $passiveMap = Get-DirectoryCompareMap -RootPath $passive.Path -Recursive $recursive
        $activeOnly = 0
        $passiveOnly = 0
        $changed = 0
        $checked = 0
        foreach ($key in $activeMap.Keys) {
            $leftItem = $activeMap[$key]
            $different = $false
            if (-not $passiveMap.ContainsKey($key)) {
                $different = $true
                $activeOnly++
            }
            else {
                $rightItem = $passiveMap[$key]
                if ($leftItem.Length -ne $rightItem.Length) {
                    $different = $true
                    $changed++
                }
                elseif ($modeIndex -ge 1 -and $leftItem.LastWriteTime -ne $rightItem.LastWriteTime) {
                    $different = $true
                    $changed++
                }
                elseif ($modeIndex -ge 2) {
                    $checked++
                    Show-ProgressDialog -Operation 'Compare SHA256' -CurrentItem $leftItem.FullName -Index $checked -Total $activeMap.Count
                    if (Test-CancelKeyPending) {
                        Show-Message -Message 'Directory compare canceled.'
                        break
                    }
                    $leftHash = Get-FileHashSafe -Path $leftItem.FullName
                    $rightHash = Get-FileHashSafe -Path $rightItem.FullName
                    if ($leftHash -ne $rightHash) {
                        $different = $true
                        $changed++
                    }
                }
            }
            if ($different) {
                $active.Marks[$leftItem.FullName] = $true
                if ($passiveMap.ContainsKey($key)) {
                    $passive.Marks[$passiveMap[$key].FullName] = $true
                }
            }
        }
        if ($twoWay) {
            foreach ($key in $passiveMap.Keys) {
                if (-not $activeMap.ContainsKey($key)) {
                    $passiveOnly++
                    $passive.Marks[$passiveMap[$key].FullName] = $true
                }
            }
        }
        Refresh-Panel -Panel $active
        Refresh-Panel -Panel $passive
        $active.Status = ('Compare: active-only {0}, changed {1}' -f $activeOnly, $changed)
        $passive.Status = ('Compare: passive-only {0}, changed {1}' -f $passiveOnly, $changed)
        Show-Message -Message ('Compare done. Active-only {0}, passive-only {1}, changed {2}. Differences marked.' -f $activeOnly, $passiveOnly, $changed)
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Directory compare failed: {0}' -f $_.Exception.Message)
        Show-Message -Message ('Compare failed: {0}' -f $_.Exception.Message)
    }
}

function Get-HelpLines {
    return @(
        'console_commander help',
        '',
        'Owner:',
        ('  Owner: {0}' -f (Get-AppOwnerName)),
        ('  Email: {0}' -f (Get-AppOwnerEmail)),
        ('  Repository: {0}' -f (Get-AppMetadataValue -Name 'Repository')),
        '',
        'Navigation:',
        '  Tab switch active panel',
        '  Up/Down move selection, PageUp/PageDown page, Home/End first/last',
        '  Enter opens directory, views file, or executes typed command',
        '  Backspace goes to parent directory',
        '  Alt+Left/Right moves through active panel history',
        '  Ctrl+R rereads active panel, Ctrl+L repaints screen',
        '',
        'Selection:',
        '  Insert toggles mark and moves down',
        '  Space toggles mark',
        '  + selects group, \ unselects group, * inverts marks',
        '',
        'Function keys:',
        '  F1 Help, F2 User menu, F3 View, F4 Edit, F5 Copy, F6 Move',
        '  F7 Mkdir, F8 Delete, F9 PullDn, F10 Quit',
        '  F9 activates the top pull-down menu bar. Alt+L/F/C/O/R may work depending on host.',
        '  Ctrl+L forces a full repaint.',
        '  Mouse backend auto-selects Win32 or VT when host support is available. Keyboard always remains available.',
        '  Options can set backend Auto, Win32, VT, or Disabled, and can retry initialization.',
        '  Options also exposes mouse diagnostics and an event monitor toggle.',
        '  Input status shows KB+Mouse Win32, KB+Mouse VT, or Keyboard-only fallback reason.',
        '  Use -MouseDiagnostics for a console-only keyboard and mouse event test loop.',
        '',
        'Visual style:',
        '  Options can select ASCII or Unicode borders, compact mode, and color theme.',
        '  ASCII remains the safe fallback for Server Core and uncertain hosts.',
        '',
        'Safety:',
        '  Copy, move, delete, overwrite, and executable launch ask before risky action.',
        '  SafeDelete moves items to LOCALAPPDATA\ConsoleCommander\Trash when enabled.',
        '  Reparse directories are not followed recursively by internal operations.',
        '',
        'Limitations:',
        '  FTP/SFTP, true background jobs, multi-editor screen list, and ACL editing are documented stubs.',
        '  Mouse double-click depends on host support; single-click selection is the reliable mouse path.',
        '  The editor is intentionally simple and blocks binary editing.',
        '  ZIP browsing is a flat virtual list; extraction and creation are implemented.'
    )
}

function Show-HelpViewer {
    $lines = Get-HelpLines
    Show-TextViewer -Lines $lines -Title 'Help'
}

function Invoke-UserMenuAction {
    param(
        [hashtable]$Entry
    )

    $panel = Get-ActivePanel
    $items = Get-SelectedOrMarkedItems -Panel $panel
    $current = Get-CurrentItem -Panel $panel

    if ($Entry.Type -eq 'Command') {
        $expanded = Expand-CommandMacros -Command $Entry.Command -Items $items
        $lines = Invoke-CommandLineSafe -CommandLine $expanded -WorkingDirectory $panel.Path -Environment $script:LastCommandMacroEnvironment
        Show-TextViewer -Lines $lines -Title 'Command output'
        return
    }

    switch ($Entry.Action) {
        'DirectorySize' {
            if ($null -eq $current -or -not $current.IsDirectory) {
                Show-Message -Message 'Select a directory.'
                return
            }
            $summary = Get-OperationSummary -Items @($current)
            Show-Message -Message ('Directory size: {0} items, {1} bytes' -f $summary.Count, $summary.Bytes)
        }
        'HashSha256' {
            if ($null -eq $current -or $current.IsDirectory) {
                Show-Message -Message 'Select a file.'
                return
            }
            $hash = Get-FileHashSafe -Path $current.FullName
            Show-TextViewer -Lines @($current.FullName, $hash) -Title 'SHA256'
        }
        'ZipCreate' { Invoke-ZipCreate }
        'ZipExtract' { Invoke-ZipExtract }
        'OpenShellHere' { Invoke-InteractiveShellHere }
        'CopyFullPath' {
            if ($null -ne $current) {
                $script:InternalClipboard = @($current.FullName)
                Show-Message -Message 'Full path copied to internal clipboard.'
            }
        }
        'Properties' {
            if ($null -ne $current) {
                Show-Properties -Path $current.FullName
            }
        }
        default {
            Show-Message -Message 'Menu action is a safe stub.'
        }
    }
}

function Show-UserMenu {
    $names = @()
    foreach ($entry in $script:Config.UserMenu) {
        $names += [string]$entry.Name
    }
    $index = Show-MenuList -Title 'User menu' -Items $names
    if ($index -ge 0) {
        Invoke-UserMenuAction -Entry $script:Config.UserMenu[$index]
    }
}

function Invoke-ZipCreate {
    $active = Get-ActivePanel
    $items = Get-SelectedOrMarkedItems -Panel $active
    if ($items.Count -eq 0) {
        Show-Message -Message 'Nothing selected.'
        return
    }
    $defaultZip = Join-Path -Path $active.Path -ChildPath 'archive.zip'
    $zipPath = Read-DialogLine -Prompt 'ZIP path' -Default $defaultZip
    if ([string]::IsNullOrWhiteSpace($zipPath)) {
        return
    }
    $paths = @()
    foreach ($item in $items) {
        $paths += $item.FullName
    }
    if (New-ZipFromPaths -Paths $paths -ZipPath $zipPath -BasePath $active.Path) {
        Refresh-Panel -Panel $active
        Show-Message -Message 'ZIP created.'
    }
    else {
        Show-Message -Message 'ZIP create failed. See log.'
    }
}

function Invoke-ZipExtract {
    $active = Get-ActivePanel
    $passive = Get-PassivePanel
    $current = Get-CurrentItem -Panel $active
    if ($null -eq $current -or $current.IsDirectory -or ([System.IO.Path]::GetExtension($current.FullName).ToLowerInvariant() -ne '.zip')) {
        Show-Message -Message 'Select a ZIP file.'
        return
    }
    $destination = Read-DialogLine -Prompt 'Extract to' -Default $passive.Path
    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }
    if (Expand-ZipSafe -ZipPath $current.FullName -DestinationPath $destination) {
        Refresh-Panel -Panel $active
        Refresh-Panel -Panel $passive
        Show-Message -Message 'ZIP extracted.'
    }
    else {
        Show-Message -Message 'ZIP extract failed. See log.'
    }
}

function Browse-ZipVirtual {
    $panel = Get-ActivePanel
    $current = Get-CurrentItem -Panel $panel
    if ($null -eq $current -or $current.IsDirectory -or ([System.IO.Path]::GetExtension($current.FullName).ToLowerInvariant() -ne '.zip')) {
        Show-Message -Message 'Select a ZIP file.'
        return
    }
    $items = Get-ZipVirtualItems -ZipPath $current.FullName
    Set-PanelVirtualItems -Panel $panel -Provider 'Zip' -Title ('ZIP: {0}' -f $current.Name) -Items $items -ReturnPath $panel.Path
}

function Get-TopMenuDefinitions {
    $leftItems = @(
        @{ Text = 'Brief listing'; Action = 'BriefListing' },
        @{ Text = 'Full listing'; Action = 'FullListing' },
        @{ Text = 'Sort by name'; Action = 'SortName' },
        @{ Text = 'Sort by extension'; Action = 'SortExtension' },
        @{ Text = 'Sort by size'; Action = 'SortSize' },
        @{ Text = 'Sort by modified time'; Action = 'SortModified' },
        @{ Text = 'Reverse sort'; Action = 'ReverseSort' },
        @{ Text = 'Filter'; Action = 'Filter' },
        @{ Text = 'Reread'; Action = 'Reread' },
        @{ Text = 'Drive list'; Action = 'DriveList' },
        @{ Text = 'Bookmarks'; Action = 'Bookmarks' },
        @{ Text = 'Back'; Action = 'Back' }
    )
    $fileItems = @(
        @{ Text = 'View'; Action = 'View' },
        @{ Text = 'Edit'; Action = 'Edit' },
        @{ Text = 'New file'; Action = 'NewFile' },
        @{ Text = 'Copy'; Action = 'Copy' },
        @{ Text = 'Move/Rename'; Action = 'Move' },
        @{ Text = 'Mkdir'; Action = 'Mkdir' },
        @{ Text = 'Delete'; Action = 'Delete' },
        @{ Text = 'Properties'; Action = 'Properties' },
        @{ Text = 'Attributes'; Action = 'Attributes' },
        @{ Text = 'Links'; Action = 'Links' },
        @{ Text = 'Create ZIP'; Action = 'ZipCreate' },
        @{ Text = 'Extract ZIP'; Action = 'ZipExtract' },
        @{ Text = 'Browse ZIP'; Action = 'ZipBrowse' },
        @{ Text = 'Trash'; Action = 'Trash' },
        @{ Text = 'Quit'; Action = 'Quit' }
    )
    $commandItems = @(
        @{ Text = 'Run command'; Action = 'RunCommand' },
        @{ Text = 'Find file'; Action = 'FindFile' },
        @{ Text = 'Quick search'; Action = 'QuickSearch' },
        @{ Text = 'External panelize'; Action = 'Panelize' },
        @{ Text = 'Directory compare'; Action = 'DirectoryCompare' },
        @{ Text = 'Diff selected files'; Action = 'Diff' },
        @{ Text = 'Command history'; Action = 'CommandHistory' },
        @{ Text = 'Hash selected file SHA256'; Action = 'HashSha256' },
        @{ Text = 'Copy selected full path'; Action = 'CopyFullPath' }
    )
    $optionItems = @(
        @{ Text = 'Toggle colors'; Action = 'ToggleColors' },
        @{ Text = 'Toggle ASCII borders'; Action = 'ToggleAscii' },
        @{ Text = 'Toggle hidden/system files'; Action = 'ToggleHidden' },
        @{ Text = 'Toggle directory-first sorting'; Action = 'ToggleDirectoryFirst' },
        @{ Text = 'Toggle reverse sort'; Action = 'ReverseSort' },
        @{ Text = 'Toggle safe delete'; Action = 'ToggleSafeDelete' },
        @{ Text = 'Toggle confirm copy'; Action = 'ToggleConfirmCopy' },
        @{ Text = 'Toggle confirm move'; Action = 'ToggleConfirmMove' },
        @{ Text = 'Toggle confirm delete'; Action = 'ToggleConfirmDelete' },
        @{ Text = 'Toggle confirm execute'; Action = 'ToggleConfirmExecute' },
        @{ Text = 'Input/mouse: mouse backend'; Action = 'MouseBackend' },
        @{ Text = 'Input/mouse: retry mouse init'; Action = 'RetryMouse' },
        @{ Text = 'Input/mouse: diagnostics'; Action = 'MouseDiagnostics' },
        @{ Text = 'Input/mouse: toggle event monitor'; Action = 'ToggleMouseEventMonitor' },
        @{ Text = 'Input/mouse: show status'; Action = 'InputStatus' },
        @{ Text = 'Enable mouse (auto)'; Action = 'EnableMouse' },
        @{ Text = 'Disable mouse'; Action = 'DisableMouse' },
        @{ Text = 'Border style'; Action = 'BorderStyle' },
        @{ Text = 'Compact mode'; Action = 'CompactMode' },
        @{ Text = 'Color theme'; Action = 'ColorTheme' },
        @{ Text = 'Default encoding'; Action = 'DefaultEncoding' },
        @{ Text = 'Save config'; Action = 'SaveConfig' },
        @{ Text = 'Reload config'; Action = 'ReloadConfig' },
        @{ Text = 'Documented stubs'; Action = 'ShowStubs' },
        @{ Text = 'About'; Action = 'About' }
    )
    $rightItems = @()
    foreach ($item in $leftItems) {
        $rightItems += @{ Text = $item.Text; Action = $item.Action }
    }

    return @(
        @{ Name = 'Left'; Target = 'Left'; Items = $leftItems },
        @{ Name = 'File'; Target = 'Active'; Items = $fileItems },
        @{ Name = 'Command'; Target = 'Active'; Items = $commandItems },
        @{ Name = 'Options'; Target = 'Active'; Items = $optionItems },
        @{ Name = 'Right'; Target = 'Right'; Items = $rightItems }
    )
}

function Get-TopMenuHeadingAt {
    param(
        [int]$X,
        [int]$Y
    )

    if ($Y -ne 0) {
        return -1
    }
    foreach ($zone in $script:RenderState.TopMenuZones) {
        if ($X -ge $zone.Left -and $X -le $zone.Right) {
            return [int]$zone.Index
        }
    }
    return -1
}

function Get-DropdownItemAt {
    param(
        [int]$X,
        [int]$Y
    )

    foreach ($zone in $script:RenderState.DropdownZones) {
        if ($Y -eq $zone.Top -and $X -ge $zone.Left -and $X -le $zone.Right) {
            return [int]$zone.Index
        }
    }
    return -1
}

function Draw-DropdownMenu {
    param(
        [hashtable]$Menu,
        [int]$MenuIndex,
        [int]$SelectedIndex
    )

    $size = Get-ConsoleSizeSafe
    $screenWidth = $size.Width
    $screenHeight = $size.Height
    $heading = $script:RenderState.TopMenuZones[$MenuIndex]
    $maxLength = $Menu.Name.Length
    foreach ($item in $Menu.Items) {
        if ($item.Text.Length -gt $maxLength) { $maxLength = $item.Text.Length }
    }
    $width = $maxLength + 4
    if ($width -lt 16) { $width = 16 }
    if ($width -gt ($screenWidth - 2)) { $width = $screenWidth - 2 }
    $left = $heading.Left
    if (($left + $width) -gt $screenWidth) {
        $left = [Math]::Max(0, $screenWidth - $width)
    }
    $top = 1
    $height = $Menu.Items.Count + 2
    if (($top + $height) -gt $screenHeight) {
        $height = [Math]::Max(3, $screenHeight - $top)
    }
    $visibleItems = [Math]::Min($Menu.Items.Count, $height - 2)
    $firstVisible = 0
    if ($SelectedIndex -ge $visibleItems) {
        $firstVisible = $SelectedIndex - $visibleItems + 1
    }

    $script:RenderState.DropdownZones = @()
    $script:RenderState.DropdownRect = [pscustomobject]@{ Left = $left; Top = $top; Right = $left + $width - 1; Bottom = $top + $visibleItems + 1 }
    $border = Get-BorderCharacters
    $colors = Get-ThemeColors
    $topChars = ($border.TopLeft + ($border.Horizontal * ($width - 2)) + $border.TopRight).ToCharArray()
    $anchor = [Math]::Max($left + 1, [Math]::Min($left + $width - 2, [int](($heading.Left + $heading.Right) / 2)))
    $anchorOffset = $anchor - $left
    if ($anchorOffset -gt 0 -and $anchorOffset -lt ($topChars.Length - 1)) {
        $topChars[$anchorOffset] = [char]$border.TDown
    }
    $topText = Convert-CharArrayToString -Characters $topChars
    Write-At -Left $left -Top $top -Text $topText -Width $width -Foreground $colors.MenuForeground -Background $colors.MenuBackground
    for ($i = 0; $i -lt $visibleItems; $i++) {
        $itemIndex = $firstVisible + $i
        if ($itemIndex -ge $Menu.Items.Count) {
            break
        }
        $fg = $colors.MenuForeground
        $bg = $colors.MenuBackground
        if ($itemIndex -eq $SelectedIndex) {
            $fg = $colors.MenuActiveForeground
            $bg = $colors.MenuActiveBackground
        }
        $text = $border.Vertical + ' ' + (Truncate-Text -Text $Menu.Items[$itemIndex].Text -Width ($width - 4)) + ' ' + $border.Vertical
        if (-not [bool]$script:Config.UseColor -and $itemIndex -eq $SelectedIndex) {
            $text = $border.Vertical + '>' + (Truncate-Text -Text $Menu.Items[$itemIndex].Text -Width ($width - 4)) + '<' + $border.Vertical
        }
        Write-At -Left $left -Top ($top + 1 + $i) -Text $text -Width $width -Foreground $fg -Background $bg
        $script:RenderState.DropdownZones += [pscustomobject]@{ Index = $itemIndex; Left = $left; Right = $left + $width - 1; Top = $top + 1 + $i }
    }
    Write-At -Left $left -Top ($top + $visibleItems + 1) -Text ($border.BottomLeft + ($border.Horizontal * ($width - 2)) + $border.BottomRight) -Width $width -Foreground $colors.MenuForeground -Background $colors.MenuBackground
}

function Invoke-TopMenuAction {
    param(
        [hashtable]$Menu,
        [hashtable]$Item
    )

    $oldActive = $script:State.ActivePanel
    if ($Menu.Target -eq 'Left') {
        $script:State.ActivePanel = 'Left'
    }
    elseif ($Menu.Target -eq 'Right') {
        $script:State.ActivePanel = 'Right'
    }

    $panel = Get-ActivePanel
    switch ($Item.Action) {
        'BriefListing' { Show-Message -Message 'Brief listing mode is not separate yet. Full listing is active.' }
        'FullListing' { Show-Message -Message 'Full listing mode is active.' }
        'SortName' { $script:Config.SortBy = 'name'; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'SortExtension' { $script:Config.SortBy = 'extension'; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'SortSize' { $script:Config.SortBy = 'size'; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'SortModified' { $script:Config.SortBy = 'modified'; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'ReverseSort' { $script:Config.ReverseSort = -not [bool]$script:Config.ReverseSort; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'Filter' { Show-FilterDialog -Panel $panel }
        'Reread' { Refresh-Panel -Panel $panel }
        'DriveList' { [void](Set-PanelLocalPath -Panel $panel -Path $script:DriveProviderPath) }
        'Bookmarks' { Show-BookmarkMenu }
        'Back' { Navigate-Parent }
        'View' { Invoke-View }
        'Edit' { Invoke-Edit }
        'NewFile' { Invoke-NewFile }
        'Copy' { Invoke-Copy }
        'Move' { Invoke-Move }
        'Mkdir' { Invoke-Mkdir }
        'Delete' { Invoke-Delete }
        'Properties' {
            $current = Get-CurrentItem -Panel $panel
            if ($null -ne $current) { Show-Properties -Path $current.FullName } else { Show-Message -Message 'No item selected.' }
        }
        'Attributes' { Show-AttributeMenu }
        'Links' { Show-LinkMenu }
        'ZipCreate' { Invoke-ZipCreate }
        'ZipExtract' { Invoke-ZipExtract }
        'ZipBrowse' { Browse-ZipVirtual }
        'Trash' { Show-TrashMenu }
        'Quit' {
            if (Confirm-Dialog -Message 'Quit console_commander?' -DefaultYes $true) {
                $script:State.ExitRequested = $true
            }
        }
        'RunCommand' {
            $command = Read-DialogLine -Prompt 'Command' -Default ''
            if (-not [string]::IsNullOrWhiteSpace($command)) {
                $script:Config.CommandHistory += $command
                [void](Save-AppConfig)
                $lines = Invoke-CommandLineSafe -CommandLine $command -WorkingDirectory $panel.Path
                Show-TextViewer -Lines $lines -Title 'Command output'
            }
        }
        'FindFile' { Invoke-SearchDialog }
        'QuickSearch' { Invoke-QuickSearch }
        'Panelize' { Invoke-ExternalPanelize }
        'DirectoryCompare' { Compare-Directories }
        'Diff' { Show-DiffViewer }
        'CommandHistory' { Show-TextViewer -Lines ([string[]]$script:Config.CommandHistory) -Title 'Command history' }
        'HashSha256' {
            $current = Get-CurrentItem -Panel $panel
            if ($null -ne $current -and -not $current.IsDirectory) {
                Show-TextViewer -Lines @($current.FullName, (Get-FileHashSafe -Path $current.FullName)) -Title 'SHA256'
            }
            else {
                Show-Message -Message 'Select a file.'
            }
        }
        'CopyFullPath' {
            $current = Get-CurrentItem -Panel $panel
            if ($null -ne $current) {
                $script:InternalClipboard = @($current.FullName)
                Show-Message -Message 'Full path copied to internal clipboard.'
            }
        }
        'ToggleColors' { $script:Config.UseColor = -not [bool]$script:Config.UseColor; Request-FullRedraw }
        'ToggleAscii' { $script:Config.UseAscii = -not [bool]$script:Config.UseAscii; if ($script:Config.UseAscii) { $script:Config.BorderStyle = 'ASCII' } else { $script:Config.BorderStyle = 'Unicode' }; Initialize-UiTheme; Request-FullRedraw }
        'ToggleHidden' { $script:Config.ShowHidden = -not [bool]$script:Config.ShowHidden; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'ToggleDirectoryFirst' { $script:Config.DirectoryFirst = -not [bool]$script:Config.DirectoryFirst; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel }
        'ToggleSafeDelete' { $script:Config.SafeDelete = -not [bool]$script:Config.SafeDelete }
        'ToggleConfirmCopy' { $script:Config.ConfirmCopy = -not [bool]$script:Config.ConfirmCopy }
        'ToggleConfirmMove' { $script:Config.ConfirmMove = -not [bool]$script:Config.ConfirmMove }
        'ToggleConfirmDelete' { $script:Config.ConfirmDelete = -not [bool]$script:Config.ConfirmDelete }
        'ToggleConfirmExecute' { $script:Config.ConfirmExecute = -not [bool]$script:Config.ConfirmExecute }
        'EnableMouse' { Enable-MouseInputMode }
        'DisableMouse' { Disable-MouseInputMode }
        'RetryMouse' { Retry-MouseInputMode }
        'InputStatus' { Show-InputModeStatus }
        'MouseDiagnostics' { Show-MouseDiagnosticsViewer }
        'MouseBackend' {
            $backendIndex = Show-MenuList -Title 'Mouse backend' -Items @('Auto', 'Win32', 'VT', 'Disabled')
            if ($backendIndex -ge 0) {
                $backendMode = @('Auto', 'Win32', 'VT', 'Disabled')[$backendIndex]
                Set-MouseBackendPreference -Mode $backendMode
            }
        }
        'ToggleMouseEventMonitor' {
            $script:MouseEventMonitorEnabled = -not [bool]$script:MouseEventMonitorEnabled
            if ($script:MouseEventMonitorEnabled) {
                Show-Message -Message 'Mouse event monitor is ON. Events are written to the app log.'
            }
            else {
                Show-Message -Message 'Mouse event monitor is OFF.'
            }
        }
        'BorderStyle' {
            $styleIndex = Show-MenuList -Title 'Border style' -Items @('ASCII', 'Unicode')
            if ($styleIndex -ge 0) {
                $script:Config.BorderStyle = @('ASCII', 'Unicode')[$styleIndex]
                $script:Config.UseAscii = ($script:Config.BorderStyle -eq 'ASCII')
                Initialize-UiTheme
                Request-FullRedraw
            }
        }
        'CompactMode' {
            $compactIndex = Show-MenuList -Title 'Compact mode' -Items @('Auto', 'On', 'Off')
            if ($compactIndex -ge 0) {
                $script:Config.CompactMode = @('Auto', 'On', 'Off')[$compactIndex]
                Request-FullRedraw
            }
        }
        'ColorTheme' {
            $themeIndex = Show-MenuList -Title 'Color theme' -Items @('Classic blue', 'Monochrome', 'High contrast')
            if ($themeIndex -ge 0) {
                $script:Config.ColorTheme = @('Classic blue', 'Monochrome', 'High contrast')[$themeIndex]
                Initialize-UiTheme
                Request-FullRedraw
            }
        }
        'DefaultEncoding' {
            $encodingIndex = Show-MenuList -Title 'Default encoding' -Items @('UTF8', 'UTF8BOM', 'ASCII', 'UTF16LE')
            if ($encodingIndex -ge 0) {
                $script:Config.DefaultEncoding = @('UTF8', 'UTF8BOM', 'ASCII', 'UTF16LE')[$encodingIndex]
            }
        }
        'SaveConfig' { if (Save-AppConfig) { Show-Message -Message 'Config saved.' } else { Show-Message -Message 'Config save failed.' } }
        'ReloadConfig' { $script:Config = Load-AppConfig; Initialize-ConfigRuntime; Refresh-Panel -Panel $script:State.LeftPanel; Refresh-Panel -Panel $script:State.RightPanel; Show-Message -Message 'Config reloaded.' }
        'ShowStubs' { Show-StubMenu }
        'About' { Show-TextViewer -Lines (Get-AboutLines) -Title 'About' }
    }

    if ($Menu.Target -eq 'Active') {
        $script:State.ActivePanel = $oldActive
    }
    $script:RenderState.OpenTopMenuIndex = -1
    Request-FullRedraw
}

function Show-TopPullDownMenu {
    param(
        [int]$InitialIndex = 0
    )

    $menus = Get-TopMenuDefinitions
    $menuIndex = $InitialIndex
    if ($menuIndex -lt 0 -or $menuIndex -ge $menus.Count) {
        $menuIndex = 0
    }
    $selected = 0
    $needDropdownRedraw = $true
    $script:RenderState.OpenTopMenuIndex = $menuIndex
    # English: Draw the base app once, then redraw only the dropdown overlay while navigating.
    # Magyar: Az alap kepernyo egyszer rajzolodik, utana navigalas kozben csak a dropdown overlay frissul.
    Render-App

    while ($true) {
        if ($needDropdownRedraw) {
            Draw-DropdownMenu -Menu $menus[$menuIndex] -MenuIndex $menuIndex -SelectedIndex $selected
            $needDropdownRedraw = $false
        }
        $event = Read-InputEvent
        if ($event.Type -eq 'Resize') {
            Request-FullRedraw
            Render-App
            $selected = 0
            $needDropdownRedraw = $true
            continue
        }
        if ($event.Type -eq 'Mouse' -and $event.ButtonDown) {
            $heading = Get-TopMenuHeadingAt -X $event.X -Y $event.Y
            if ($heading -ge 0) {
                if ($heading -ne $menuIndex -and $null -ne $script:RenderState.DropdownRect) {
                    Restore-ScreenRows -Top $script:RenderState.DropdownRect.Top -Bottom $script:RenderState.DropdownRect.Bottom
                }
                $menuIndex = $heading
                $script:RenderState.OpenTopMenuIndex = $menuIndex
                $selected = 0
                $needDropdownRedraw = $true
                continue
            }
            $itemIndex = Get-DropdownItemAt -X $event.X -Y $event.Y
            if ($itemIndex -ge 0 -and $itemIndex -lt $menus[$menuIndex].Items.Count) {
                Invoke-TopMenuAction -Menu $menus[$menuIndex] -Item $menus[$menuIndex].Items[$itemIndex]
                return
            }
            Request-FullRedraw
            return
        }
        if ($event.Type -ne 'Key') {
            continue
        }

        $key = $event.KeyInfo
        switch ($key.Key) {
            ([ConsoleKey]::LeftArrow) {
                if ($null -ne $script:RenderState.DropdownRect) {
                    Restore-ScreenRows -Top $script:RenderState.DropdownRect.Top -Bottom $script:RenderState.DropdownRect.Bottom
                }
                $menuIndex--
                if ($menuIndex -lt 0) { $menuIndex = $menus.Count - 1 }
                $script:RenderState.OpenTopMenuIndex = $menuIndex
                $selected = 0
                $needDropdownRedraw = $true
            }
            ([ConsoleKey]::RightArrow) {
                if ($null -ne $script:RenderState.DropdownRect) {
                    Restore-ScreenRows -Top $script:RenderState.DropdownRect.Top -Bottom $script:RenderState.DropdownRect.Bottom
                }
                $menuIndex++
                if ($menuIndex -ge $menus.Count) { $menuIndex = 0 }
                $script:RenderState.OpenTopMenuIndex = $menuIndex
                $selected = 0
                $needDropdownRedraw = $true
            }
            ([ConsoleKey]::UpArrow) {
                if ($selected -gt 0) { $selected-- }
                $needDropdownRedraw = $true
            }
            ([ConsoleKey]::DownArrow) {
                if ($selected -lt ($menus[$menuIndex].Items.Count - 1)) { $selected++ }
                $needDropdownRedraw = $true
            }
            ([ConsoleKey]::Home) { $selected = 0; $needDropdownRedraw = $true }
            ([ConsoleKey]::End) { $selected = $menus[$menuIndex].Items.Count - 1; $needDropdownRedraw = $true }
            ([ConsoleKey]::Enter) {
                Invoke-TopMenuAction -Menu $menus[$menuIndex] -Item $menus[$menuIndex].Items[$selected]
                return
            }
            ([ConsoleKey]::Escape) {
                $script:RenderState.OpenTopMenuIndex = -1
                Request-FullRedraw
                return
            }
        }
    }
}

function Show-MainMenu {
    Show-TopPullDownMenu -InitialIndex 0
}

function Show-AttributeMenu {
    $panel = Get-ActivePanel
    $current = Get-CurrentItem -Panel $panel
    if ($null -eq $current) {
        Show-Message -Message 'No item selected.'
        return
    }
    $index = Show-MenuList -Title 'Attributes' -Items @('Show properties', 'Toggle ReadOnly', 'Toggle Hidden', 'Toggle Archive', 'Toggle System', 'ACL viewer', 'ACL editor stub', 'Back')
    switch ($index) {
        0 { Show-Properties -Path $current.FullName }
        1 { [void](Toggle-Attribute -Path $current.FullName -Attribute ([System.IO.FileAttributes]::ReadOnly)); Refresh-Panel -Panel $panel }
        2 { [void](Toggle-Attribute -Path $current.FullName -Attribute ([System.IO.FileAttributes]::Hidden)); Refresh-Panel -Panel $panel }
        3 { [void](Toggle-Attribute -Path $current.FullName -Attribute ([System.IO.FileAttributes]::Archive)); Refresh-Panel -Panel $panel }
        4 { [void](Toggle-Attribute -Path $current.FullName -Attribute ([System.IO.FileAttributes]::System)); Refresh-Panel -Panel $panel }
        5 { Show-Properties -Path $current.FullName }
        6 { Show-Message -Message 'ACL editor is not implemented. Read-only ACL viewer is available.' }
    }
}

function New-LinkSafe {
    param(
        [string]$ItemType,
        [string]$TargetPath,
        [string]$LinkPath
    )

    try {
        $parent = Split-Path -Path $LinkPath -Parent
        New-DirectoryIfMissing -Path $parent
        [void](New-Item -ItemType $ItemType -Path $LinkPath -Target $TargetPath -ErrorAction Stop)
        Show-Message -Message ('{0} created.' -f $ItemType)
        return $true
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Link create failed {0} -> {1}: {2}' -f $LinkPath, $TargetPath, $_.Exception.Message)
        Show-Message -Message ('Cannot create {0}: {1}' -f $ItemType, $_.Exception.Message)
        return $false
    }
}

function Show-LinkMenu {
    $panel = Get-ActivePanel
    $current = Get-CurrentItem -Panel $panel
    if ($null -eq $current -or $current.IsParent) {
        Show-Message -Message 'No item selected.'
        return
    }

    $index = Show-MenuList -Title 'Links' -Items @('Create hard link', 'Create symbolic link', 'Create directory junction', 'Back')
    if ($index -lt 0 -or $index -eq 3) {
        return
    }

    if ($index -eq 0 -and $current.IsDirectory) {
        Show-Message -Message 'Hard links are for files only.'
        return
    }
    if ($index -eq 2 -and -not $current.IsDirectory) {
        Show-Message -Message 'Junctions are for directories only.'
        return
    }

    $defaultName = $current.Name + '.link'
    if ($index -eq 2) {
        $defaultName = $current.Name + '.junction'
    }
    $defaultPath = Join-Path -Path $panel.Path -ChildPath $defaultName
    $linkPath = Read-DialogLine -Prompt 'Link path' -Default $defaultPath
    if ([string]::IsNullOrWhiteSpace($linkPath)) {
        return
    }

    if ($index -eq 0) {
        [void](New-LinkSafe -ItemType 'HardLink' -TargetPath $current.FullName -LinkPath $linkPath)
    }
    elseif ($index -eq 1) {
        [void](New-LinkSafe -ItemType 'SymbolicLink' -TargetPath $current.FullName -LinkPath $linkPath)
    }
    elseif ($index -eq 2) {
        [void](New-LinkSafe -ItemType 'Junction' -TargetPath $current.FullName -LinkPath $linkPath)
    }
    Refresh-Panel -Panel $panel
}

function Get-TrashRootPath {
    return (Join-Path -Path $script:LocalDataPath -ChildPath 'Trash')
}

function Get-TrashMetadataItems {
    $trashRoot = Get-TrashRootPath
    $metadataRoot = Join-Path -Path $trashRoot -ChildPath '_metadata'
    $items = @()
    if (-not (Test-Path -LiteralPath $metadataRoot -PathType Container)) {
        return $items
    }
    $files = @(Get-ChildItem -LiteralPath $metadataRoot -Filter '*.json' -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        try {
            $data = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop)
            $items += [pscustomobject]@{
                MetadataPath = $file.FullName
                OriginalPath = [string]$data.OriginalPath
                TrashPath = [string]$data.TrashPath
                DeletedAt = [string]$data.DeletedAt
                IsDirectory = [bool]$data.IsDirectory
            }
        }
        catch {
            Write-AppLog -Level 'WARN' -Message ('Trash metadata read failed {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
    }
    return $items
}

function Show-TrashViewer {
    $items = @(Get-TrashMetadataItems)
    $lines = @('Trash items:', '')
    if ($items.Count -eq 0) {
        $lines += 'Trash is empty or metadata is missing.'
    }
    foreach ($item in $items) {
        $lines += ('Deleted: {0}' -f $item.DeletedAt)
        $lines += ('Original: {0}' -f $item.OriginalPath)
        $lines += ('Trash: {0}' -f $item.TrashPath)
        $lines += ''
    }
    Show-TextViewer -Lines $lines -Title 'Trash'
}

function Restore-TrashItem {
    $items = @(Get-TrashMetadataItems)
    if ($items.Count -eq 0) {
        Show-Message -Message 'Trash is empty.'
        return
    }
    $names = @()
    foreach ($item in $items) {
        $names += ('{0} -> {1}' -f (Split-Path -Path $item.TrashPath -Leaf), $item.OriginalPath)
    }
    $index = Show-MenuList -Title 'Restore trash item' -Items $names
    if ($index -lt 0) { return }
    $item = $items[$index]
    $restorePath = $item.OriginalPath
    if ([string]::IsNullOrWhiteSpace($restorePath) -or (Test-Path -LiteralPath $restorePath)) {
        $restorePath = Read-DialogLine -Prompt 'Restore to' -Default $restorePath
    }
    if ([string]::IsNullOrWhiteSpace($restorePath)) { return }
    try {
        $parent = Split-Path -Path $restorePath -Parent
        New-DirectoryIfMissing -Path $parent
        $overwritePolicy = 'Ask'
        $result = Move-PathSafe -Source $item.TrashPath -Destination $restorePath -OverwritePolicy ([ref]$overwritePolicy)
        if ($result -ne 'Moved') {
            if ($result -eq 'Cancel' -or $result -eq 'Skipped') {
                Show-Message -Message 'Trash restore canceled.'
                return
            }
            throw 'Safe trash restore failed.'
        }
        Remove-Item -LiteralPath $item.MetadataPath -Force -ErrorAction SilentlyContinue
        Show-Message -Message 'Trash item restored.'
        Refresh-Panel -Panel $script:State.LeftPanel
        Refresh-Panel -Panel $script:State.RightPanel
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Trash restore failed {0}: {1}' -f $item.TrashPath, $_.Exception.Message)
        Show-Message -Message ('Restore failed: {0}' -f $_.Exception.Message)
    }
}

function Purge-Trash {
    $trashRoot = Get-TrashRootPath
    if (-not (Test-Path -LiteralPath $trashRoot -PathType Container)) {
        Show-Message -Message 'Trash is empty.'
        return
    }
    if (-not (Confirm-Dialog -Message ('Permanently purge trash at {0}?' -f $trashRoot) -DefaultYes $false)) {
        return
    }
    try {
        Get-ChildItem -LiteralPath $trashRoot -Force -ErrorAction Stop | Remove-Item -Recurse -Force -ErrorAction Stop
        Show-Message -Message 'Trash purged.'
    }
    catch {
        Write-AppLog -Level 'ERROR' -Message ('Trash purge failed: {0}' -f $_.Exception.Message)
        Show-Message -Message ('Purge failed: {0}' -f $_.Exception.Message)
    }
}

function Show-TrashMenu {
    $index = Show-MenuList -Title 'Trash' -Items @('View trash', 'Restore selected trash item', 'Purge trash', 'Back')
    switch ($index) {
        0 { Show-TrashViewer }
        1 { Restore-TrashItem }
        2 { Purge-Trash }
    }
}

function Show-BookmarkMenu {
    $panel = Get-ActivePanel
    $items = @('Add active path')
    foreach ($bookmark in $script:Config.Bookmarks) {
        $items += [string]$bookmark
    }
    $items += 'Back'
    $index = Show-MenuList -Title 'Bookmarks' -Items $items
    if ($index -eq 0) {
        if ($script:Config.Bookmarks -notcontains $panel.Path) {
            $script:Config.Bookmarks += $panel.Path
            [void](Save-AppConfig)
        }
        return
    }
    if ($index -gt 0 -and $index -le $script:Config.Bookmarks.Count) {
        [void](Set-PanelLocalPath -Panel $panel -Path $script:Config.Bookmarks[$index - 1])
    }
}

function Show-StubMenu {
    # English: TODO - Keep these safe stubs visible until a dependency-free implementation exists.
    # Magyar: TODO - Ezek a biztonsagos stubok maradjanak lathatok, amig nincs dependency-free implementacio.
    $lines = @(
        'Documented safe stubs:',
        '',
        'FTP provider: not implemented because Windows PowerShell 5.1 has no native secure dependency-free FTP/SFTP provider suitable for Server Core.',
        'SFTP provider: not implemented for the same reason; no external modules or binaries are allowed.',
        'Mouse support: Win32 and VT backends are implemented where host support exists; keyboard-only fallback remains primary.',
        'Background jobs: true MC-style background copy/move is not implemented; operations show progress points and ask before risk.',
        'Multiple editor windows: not implemented; one reliable internal editor session is provided.',
        'ACL editor: not implemented; read-only ACL viewer is provided.',
        'TAR: optional through tar.exe detection only; ZIP is the built-in archive format.'
    )
    Show-TextViewer -Lines $lines -Title 'Stubs'
}

function Invoke-Copy {
    $active = Get-ActivePanel
    $passive = Get-PassivePanel
    $items = Get-SelectedOrMarkedItems -Panel $active
    if ($items.Count -eq 0) {
        Show-Message -Message 'Nothing selected.'
        return
    }
    $destination = Read-DialogLine -Prompt 'Copy to' -Default $passive.Path
    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }
    if (Copy-ItemsToDirectory -Items $items -DestinationDirectory $destination) {
        $active.Marks = @{}
        Refresh-Panel -Panel $active
        Refresh-Panel -Panel $passive
    }
}

function Invoke-Move {
    $active = Get-ActivePanel
    $passive = Get-PassivePanel
    $items = Get-SelectedOrMarkedItems -Panel $active
    if ($items.Count -eq 0) {
        Show-Message -Message 'Nothing selected.'
        return
    }
    $defaultDest = $passive.Path
    if ($items.Count -eq 1) {
        $defaultDest = Join-Path -Path $active.Path -ChildPath $items[0].Name
    }
    $destination = Read-DialogLine -Prompt 'Move/rename to directory or path' -Default $defaultDest
    if ([string]::IsNullOrWhiteSpace($destination)) {
        return
    }

    if ($items.Count -eq 1 -and -not (Test-Path -LiteralPath $destination -PathType Container)) {
        $overwritePolicy = 'Ask'
        $result = Move-PathSafe -Source $items[0].FullName -Destination $destination -OverwritePolicy ([ref]$overwritePolicy)
        if ($result -ne 'Cancel') {
            $active.Marks = @{}
            Refresh-Panel -Panel $active
            Refresh-Panel -Panel $passive
        }
    }
    else {
        if (Move-ItemsToDirectory -Items $items -DestinationDirectory $destination) {
            $active.Marks = @{}
            Refresh-Panel -Panel $active
            Refresh-Panel -Panel $passive
        }
    }
}

function Invoke-Delete {
    $active = Get-ActivePanel
    $items = Get-SelectedOrMarkedItems -Panel $active
    if (Delete-ItemsSafe -Items $items) {
        $active.Marks = @{}
        Refresh-Panel -Panel $active
    }
}

function Invoke-Mkdir {
    $active = Get-ActivePanel
    if ($active.Provider -ne 'Local') {
        Show-Message -Message 'Mkdir requires local panel.'
        return
    }
    $name = Read-DialogLine -Prompt 'Directory name' -Default 'NewFolder'
    if ($null -eq $name) {
        return
    }
    if (New-DirectorySafe -ParentPath $active.Path -Name $name) {
        Refresh-Panel -Panel $active
    }
}

function Invoke-NewFile {
    $active = Get-ActivePanel
    if ($active.Provider -ne 'Local') {
        Show-Message -Message 'New file requires local panel.'
        return
    }
    $name = Read-DialogLine -Prompt 'File name' -Default 'new.txt'
    if ($null -eq $name) {
        return
    }
    if (New-FileSafe -ParentPath $active.Path -Name $name) {
        Refresh-Panel -Panel $active
    }
}

function Invoke-View {
    $active = Get-ActivePanel
    $current = Get-CurrentItem -Panel $active
    if ($null -eq $current -or $current.IsDirectory) {
        Show-Message -Message 'Select a file.'
        return
    }
    Show-FileViewer -Path $current.FullName
}

function Invoke-Edit {
    $active = Get-ActivePanel
    $target = ''
    if (-not [string]::IsNullOrWhiteSpace($script:State.CommandLine)) {
        $target = $script:State.CommandLine
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path -Path $active.Path -ChildPath $target
        }
        $script:State.CommandLine = ''
    }
    else {
        $current = Get-CurrentItem -Panel $active
        if ($null -eq $current -or $current.IsDirectory) {
            $name = Read-DialogLine -Prompt 'Edit file' -Default 'new.txt'
            if ([string]::IsNullOrWhiteSpace($name)) { return }
            $target = Join-Path -Path $active.Path -ChildPath $name
        }
        else {
            $target = $current.FullName
        }
    }
    Show-FileEditor -Path $target
    Refresh-Panel -Panel $active
}

function Invoke-EnteredCommandLine {
    param(
        [object]$Panel
    )

    if ([string]::IsNullOrWhiteSpace($script:State.CommandLine)) {
        return $false
    }

    $command = $script:State.CommandLine
    $script:State.CommandLine = ''
    $script:Config.CommandHistory += $command
    if (-not $script:NonInteractiveMode) {
        [void](Save-AppConfig)
    }
    $lines = Invoke-CommandLineSafe -CommandLine $command -WorkingDirectory $Panel.Path
    $script:LastCommandLineOutput = @($lines)
    if ($script:NonInteractiveMode) {
        return $true
    }
    Show-TextViewer -Lines $lines -Title 'Command output'
    return $true
}

function Enter-CurrentItem {
    $panel = Get-ActivePanel
    $item = Get-CurrentItem -Panel $panel
    if ($null -eq $item) {
        return
    }

    if ($item.IsParent -or $item.IsDrive -or $item.IsDirectory) {
        [void](Set-PanelLocalPath -Panel $panel -Path $item.FullName)
        return
    }

    if ($panel.Provider -eq 'Zip') {
        Show-Message -Message 'ZIP entry viewing is listed only; extract ZIP to open content.'
        return
    }

    $extension = [System.IO.Path]::GetExtension($item.FullName).ToLowerInvariant()
    $executableExtensions = @('.exe', '.cmd', '.bat', '.com', '.ps1')
    if ($executableExtensions -contains $extension) {
        if (Confirm-Dialog -Message ('Execute {0}?' -f $item.Name) -DefaultYes $false -AssumeYes (-not [bool]$script:Config.ConfirmExecute)) {
            $quoted = Quote-CmdArgument -Value $item.FullName
            $lines = Invoke-CommandLineSafe -CommandLine $quoted -WorkingDirectory (Split-Path -Path $item.FullName -Parent)
            Show-TextViewer -Lines $lines -Title 'Execution output'
            return
        }
    }

    Show-FileViewer -Path $item.FullName
}

function Navigate-Parent {
    $panel = Get-ActivePanel
    if ($panel.Provider -ne 'Local') {
        [void](Set-PanelLocalPath -Panel $panel -Path $panel.ReturnPath)
        return
    }
    if ($panel.Path -eq $script:DriveProviderPath) {
        return
    }
    try {
        $parent = Split-Path -Path $panel.Path -Parent
        if ([string]::IsNullOrWhiteSpace($parent)) {
            $parent = $script:DriveProviderPath
        }
        [void](Set-PanelLocalPath -Panel $panel -Path $parent)
    }
    catch {
        [void](Set-PanelLocalPath -Panel $panel -Path $script:DriveProviderPath)
    }
}

function Get-PanelZoneAt {
    param(
        [int]$X,
        [int]$Y
    )

    $zones = @($script:RenderState.LeftPanelZone, $script:RenderState.RightPanelZone)
    foreach ($zone in $zones) {
        if ($null -eq $zone) {
            continue
        }
        if ($X -ge $zone.Left -and $X -lt ($zone.Left + $zone.Width) -and $Y -ge $zone.Top -and $Y -lt ($zone.Top + $zone.Height)) {
            return $zone
        }
    }
    return $null
}

function Set-ObjectNoteProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $InputObject) {
        return
    }
    if ($null -ne $InputObject.PSObject.Properties[$Name]) {
        $InputObject.$Name = $Value
        return
    }
    Add-Member -InputObject $InputObject -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Get-MouseButtonIdentity {
    param(
        [object]$MouseEvent
    )

    if ($null -eq $MouseEvent) {
        return 0
    }

    $buttonState = [uint32]$MouseEvent.ButtonState
    $backend = [string]$MouseEvent.Backend
    if ($backend -eq 'VT') {
        $rawButton = [int]($buttonState -band 0x00000003)
        if ($rawButton -ge 0 -and $rawButton -le 2) {
            return ($rawButton + 1)
        }
        return 0
    }

    $lowButtons = ($buttonState -band 0x0000001F)
    if (($lowButtons -band 0x00000001) -ne 0) { return 1 }
    if (($lowButtons -band 0x00000002) -ne 0) { return 2 }
    if (($lowButtons -band 0x00000004) -ne 0) { return 3 }
    if (($lowButtons -band 0x00000008) -ne 0) { return 4 }
    if (($lowButtons -band 0x00000010) -ne 0) { return 5 }
    return 0
}

function Set-MouseEventLocationFields {
    param(
        [object]$MouseEvent
    )

    if ($null -eq $MouseEvent) {
        return
    }

    $zoneKind = 'Other'
    $panelName = $null
    $rowIndex = $null

    $layout = $script:RenderState.LastLayout
    if ($null -ne $layout) {
        if ($MouseEvent.Y -eq $layout.CommandLineRow) {
            $zoneKind = 'CommandLine'
        }
        elseif ($MouseEvent.Y -eq $layout.FunctionKeyRow) {
            $zoneKind = 'FunctionKeyBar'
        }
    }

    if ((Get-TopMenuHeadingAt -X $MouseEvent.X -Y $MouseEvent.Y) -ge 0) {
        $zoneKind = 'TopMenu'
    }

    $zone = Get-PanelZoneAt -X $MouseEvent.X -Y $MouseEvent.Y
    if ($null -ne $zone) {
        $panelName = [string]$zone.Panel
        $row = [int]($MouseEvent.Y - $zone.RowTop)
        if ($row -ge 0 -and $row -lt $zone.VisibleRows) {
            $panel = $null
            if ($panelName -eq 'Left') {
                $panel = $script:State.LeftPanel
            }
            elseif ($panelName -eq 'Right') {
                $panel = $script:State.RightPanel
            }
            if ($null -ne $panel) {
                $candidateIndex = [int]$panel.TopIndex + $row
                if ($candidateIndex -ge 0 -and $candidateIndex -lt $panel.Items.Count) {
                    $zoneKind = 'PanelRow'
                    $rowIndex = $candidateIndex
                }
                else {
                    $zoneKind = 'PanelEmpty'
                }
            }
            else {
                $zoneKind = 'PanelArea'
            }
        }
        else {
            $zoneKind = 'PanelFrame'
        }
    }

    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ZoneKind' -Value $zoneKind
    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'PanelName' -Value $panelName
    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'RowIndex' -Value $rowIndex
}

function Initialize-MouseEventFields {
    param(
        [object]$MouseEvent
    )

    if ($null -eq $MouseEvent) {
        return
    }

    $defaults = @{
        ButtonUp = $false
        Click = $false
        NativeDoubleClick = $false
        SyntheticDoubleClick = $false
        SuppressedDuplicateClick = $false
        ClickElapsedMs = -1
        ClickSequence = 0
        ZoneKind = $null
        PanelName = $null
        RowIndex = $null
        ActionTaken = 'Ignored'
    }
    foreach ($key in $defaults.Keys) {
        if ($null -eq $MouseEvent.PSObject.Properties[$key]) {
            Set-ObjectNoteProperty -InputObject $MouseEvent -Name $key -Value $defaults[$key]
        }
    }

    if ($MouseEvent.DoubleClick -and -not [bool]$MouseEvent.NativeDoubleClick -and [uint32]$MouseEvent.EventFlags -eq 0x0002) {
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'NativeDoubleClick' -Value $true
    }
    if (-not [bool]$MouseEvent.Click -and [bool]$MouseEvent.ButtonDown -and [int]$MouseEvent.WheelDelta -eq 0 -and [uint32]$MouseEvent.EventFlags -ne 0x0001) {
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'Click' -Value $true
    }

    Set-MouseEventLocationFields -MouseEvent $MouseEvent
}

function Get-MouseClickIdentity {
    param(
        [object]$MouseEvent
    )

    if ($null -eq $MouseEvent) {
        return $null
    }

    return [pscustomobject]@{
        X = [int]$MouseEvent.X
        Y = [int]$MouseEvent.Y
        Button = [int](Get-MouseButtonIdentity -MouseEvent $MouseEvent)
        Time = Get-Date
        ZoneKind = [string]$MouseEvent.ZoneKind
        PanelName = [string]$MouseEvent.PanelName
        RowIndex = $MouseEvent.RowIndex
    }
}

function Update-MouseClickState {
    param(
        [object]$MouseEvent
    )

    if ($null -eq $MouseEvent) {
        return $MouseEvent
    }

    Initialize-MouseEventFields -MouseEvent $MouseEvent
    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'SyntheticDoubleClick' -Value $false
    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'SuppressedDuplicateClick' -Value $false
    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ClickElapsedMs' -Value -1

    if ([int]$MouseEvent.WheelDelta -ne 0) {
        $script:LastMouseClick = $null
        return $MouseEvent
    }
    if (-not [bool]$MouseEvent.Click -or [bool]$MouseEvent.ButtonUp) {
        return $MouseEvent
    }

    $now = Get-Date
    $currentClick = Get-MouseClickIdentity -MouseEvent $MouseEvent
    $currentClick.Time = $now
    if ($null -ne $script:LastMouseClick -and $null -ne $currentClick) {
        $elapsed = ($now - $script:LastMouseClick.Time).TotalMilliseconds
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ClickElapsedMs' -Value ([int]$elapsed)

        $sameTarget = (
            [int]$script:LastMouseClick.Button -eq [int]$currentClick.Button -and
            [string]$script:LastMouseClick.ZoneKind -eq [string]$currentClick.ZoneKind -and
            [string]$script:LastMouseClick.PanelName -eq [string]$currentClick.PanelName -and
            [string]$script:LastMouseClick.RowIndex -eq [string]$currentClick.RowIndex
        )
        $isPanelRow = ([string]$currentClick.ZoneKind -eq 'PanelRow')

        if ($sameTarget -and $isPanelRow -and $elapsed -lt 80 -and -not [bool]$MouseEvent.NativeDoubleClick) {
            Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'SuppressedDuplicateClick' -Value $true
            return $MouseEvent
        }

        if ($sameTarget -and $isPanelRow -and $elapsed -ge 120 -and $elapsed -le 500) {
            if (-not [bool]$MouseEvent.DoubleClick) {
                Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'DoubleClick' -Value $true
                Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'SyntheticDoubleClick' -Value $true
            }
            $script:LastMouseClick = $null
            return $MouseEvent
        }
    }

    if ([bool]$MouseEvent.DoubleClick) {
        $script:LastMouseClick = $null
        return $MouseEvent
    }

    if ([string]$currentClick.ZoneKind -eq 'PanelRow') {
        $script:MouseClickSequence++
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ClickSequence' -Value $script:MouseClickSequence
        $script:LastMouseClick = $currentClick
    }
    else {
        $script:LastMouseClick = $null
    }

    return $MouseEvent
}

function Write-MouseEventDebugLog {
    param(
        [object]$MouseEvent,
        [string]$Action
    )

    if (-not [bool]$script:MouseEventMonitorEnabled -or $null -eq $MouseEvent) {
        return
    }

    $selectedName = ''
    if ($MouseEvent.ZoneKind -eq 'PanelRow' -and -not [string]::IsNullOrEmpty([string]$MouseEvent.PanelName)) {
        $panel = $null
        if ([string]$MouseEvent.PanelName -eq 'Left') { $panel = $script:State.LeftPanel }
        if ([string]$MouseEvent.PanelName -eq 'Right') { $panel = $script:State.RightPanel }
        if ($null -ne $panel -and $null -ne $MouseEvent.RowIndex -and [int]$MouseEvent.RowIndex -ge 0 -and [int]$MouseEvent.RowIndex -lt $panel.Items.Count) {
            $selectedName = [string]$panel.Items[[int]$MouseEvent.RowIndex].Name
        }
    }

    Write-AppLog -Level 'INFO' -Message ('MouseEvent backend={0} x={1} y={2} down={3} up={4} click={5} dbl={6} nativeDbl={7} syntheticDbl={8} suppressed={9} elapsedMs={10} zone={11} panel={12} row={13} item={14} action={15} wheel={16} state=0x{17:X8} flags=0x{18:X8}' -f $MouseEvent.Backend, $MouseEvent.X, $MouseEvent.Y, $MouseEvent.ButtonDown, $MouseEvent.ButtonUp, $MouseEvent.Click, $MouseEvent.DoubleClick, $MouseEvent.NativeDoubleClick, $MouseEvent.SyntheticDoubleClick, $MouseEvent.SuppressedDuplicateClick, $MouseEvent.ClickElapsedMs, $MouseEvent.ZoneKind, $MouseEvent.PanelName, $MouseEvent.RowIndex, $selectedName, $Action, $MouseEvent.WheelDelta, [uint32]$MouseEvent.ButtonState, [uint32]$MouseEvent.EventFlags)
}

function Handle-MouseEvent {
    param(
        [object]$MouseEvent
    )

    $MouseEvent = Update-MouseClickState -MouseEvent $MouseEvent
    if ($null -ne $MouseEvent.PSObject.Properties['SuppressedDuplicateClick'] -and [bool]$MouseEvent.SuppressedDuplicateClick) {
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'Ignored'
        Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'Ignored'
        return
    }

    if ($MouseEvent.WheelDelta -ne 0) {
        $zone = Get-PanelZoneAt -X $MouseEvent.X -Y $MouseEvent.Y
        if ($null -ne $zone) {
            $script:State.ActivePanel = $zone.Panel
        }
        $panel = Get-ActivePanel
        if ($MouseEvent.WheelDelta -gt 0) {
            Move-Selection -Panel $panel -Delta -3 -VisibleRows $script:State.VisibleRows
        }
        else {
            Move-Selection -Panel $panel -Delta 3 -VisibleRows $script:State.VisibleRows
        }
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'Ignored'
        Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'Ignored'
        return
    }

    if (-not [bool]$MouseEvent.Click -and -not [bool]$MouseEvent.DoubleClick) {
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'Ignored'
        Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'Ignored'
        return
    }

    $menuIndex = Get-TopMenuHeadingAt -X $MouseEvent.X -Y $MouseEvent.Y
    if ($menuIndex -ge 0) {
        Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'Ignored'
        Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'Ignored'
        Show-TopPullDownMenu -InitialIndex $menuIndex
        return
    }

    $zone = Get-PanelZoneAt -X $MouseEvent.X -Y $MouseEvent.Y
    if ($null -ne $zone) {
        $script:State.ActivePanel = $zone.Panel
        $panel = Get-ActivePanel
        $row = $MouseEvent.Y - $zone.RowTop
        if ($row -ge 0 -and $row -lt $zone.VisibleRows) {
            $index = $panel.TopIndex + $row
            if ($index -ge 0 -and $index -lt $panel.Items.Count) {
                Set-SelectionAbsolute -Panel $panel -Index $index -VisibleRows $zone.VisibleRows
                if ([bool]$MouseEvent.DoubleClick -and [bool]$MouseEvent.Click) {
                    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'EnterCurrentItem'
                    Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'EnterCurrentItem'
                    Enter-CurrentItem
                }
                else {
                    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'SelectOnly'
                    Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'SelectOnly'
                }
            }
        }
        return
    }

    Set-ObjectNoteProperty -InputObject $MouseEvent -Name 'ActionTaken' -Value 'Ignored'
    Write-MouseEventDebugLog -MouseEvent $MouseEvent -Action 'Ignored'
}

function Handle-Key {
    param(
        [ConsoleKeyInfo]$KeyInfo
    )

    $panel = Get-ActivePanel
    $control = (($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
    $alt = (($KeyInfo.Modifiers -band [ConsoleModifiers]::Alt) -ne 0)

    if ($control -and $KeyInfo.Key -eq [ConsoleKey]::R) {
        Refresh-Panel -Panel $panel
        return
    }
    if ($control -and $KeyInfo.Key -eq [ConsoleKey]::L) {
        Request-FullRedraw
        Render-App
        return
    }
    if ($control -and $KeyInfo.Key -eq [ConsoleKey]::F) {
        Invoke-QuickSearch
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::S) {
        Invoke-QuickSearch
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::LeftArrow) {
        [void](Move-PanelHistory -Panel $panel -Delta -1)
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::RightArrow) {
        [void](Move-PanelHistory -Panel $panel -Delta 1)
        return
    }
    if ($control -and $KeyInfo.Key -eq [ConsoleKey]::P) {
        Move-Selection -Panel $panel -Delta -1 -VisibleRows $script:State.VisibleRows
        return
    }
    if ($control -and $KeyInfo.Key -eq [ConsoleKey]::N) {
        Move-Selection -Panel $panel -Delta 1 -VisibleRows $script:State.VisibleRows
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::L) {
        Show-TopPullDownMenu -InitialIndex 0
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::F) {
        Show-TopPullDownMenu -InitialIndex 1
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::C) {
        Show-TopPullDownMenu -InitialIndex 2
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::O) {
        Show-TopPullDownMenu -InitialIndex 3
        return
    }
    if ($alt -and $KeyInfo.Key -eq [ConsoleKey]::R) {
        Show-TopPullDownMenu -InitialIndex 4
        return
    }

    switch ($KeyInfo.Key) {
        ([ConsoleKey]::Tab) {
            if ($script:State.ActivePanel -eq 'Left') { $script:State.ActivePanel = 'Right' } else { $script:State.ActivePanel = 'Left' }
        }
        ([ConsoleKey]::UpArrow) { Move-Selection -Panel $panel -Delta -1 -VisibleRows $script:State.VisibleRows }
        ([ConsoleKey]::DownArrow) { Move-Selection -Panel $panel -Delta 1 -VisibleRows $script:State.VisibleRows }
        ([ConsoleKey]::PageUp) { Move-Selection -Panel $panel -Delta (-1 * $script:State.VisibleRows) -VisibleRows $script:State.VisibleRows }
        ([ConsoleKey]::PageDown) { Move-Selection -Panel $panel -Delta $script:State.VisibleRows -VisibleRows $script:State.VisibleRows }
        ([ConsoleKey]::Home) { Set-SelectionAbsolute -Panel $panel -Index 0 -VisibleRows $script:State.VisibleRows }
        ([ConsoleKey]::End) { Set-SelectionAbsolute -Panel $panel -Index ($panel.Items.Count - 1) -VisibleRows $script:State.VisibleRows }
        ([ConsoleKey]::Enter) {
            if (-not (Invoke-EnteredCommandLine -Panel $panel)) {
                Enter-CurrentItem
            }
        }
        ([ConsoleKey]::Backspace) {
            if ($script:State.CommandLine.Length -gt 0) {
                $script:State.CommandLine = $script:State.CommandLine.Substring(0, $script:State.CommandLine.Length - 1)
            }
            else {
                Navigate-Parent
            }
        }
        ([ConsoleKey]::Insert) { Toggle-MarkCurrent -Panel $panel -MoveDown $true }
        ([ConsoleKey]::Spacebar) { Toggle-MarkCurrent -Panel $panel -MoveDown $false }
        ([ConsoleKey]::F1) { Show-HelpViewer }
        ([ConsoleKey]::F2) { Show-UserMenu }
        ([ConsoleKey]::F3) { Invoke-View }
        ([ConsoleKey]::F4) { Invoke-Edit }
        ([ConsoleKey]::F5) { Invoke-Copy }
        ([ConsoleKey]::F6) { Invoke-Move }
        ([ConsoleKey]::F7) { Invoke-Mkdir }
        ([ConsoleKey]::F8) { Invoke-Delete }
        ([ConsoleKey]::F9) { Show-MainMenu }
        ([ConsoleKey]::F10) {
            if (Confirm-Dialog -Message 'Quit console_commander?' -DefaultYes $true) {
                $script:State.ExitRequested = $true
            }
        }
        default {
            if ($KeyInfo.KeyChar -eq '+') {
                Select-Group -Panel $panel -Unselect $false
            }
            elseif ($KeyInfo.KeyChar -eq '\') {
                Select-Group -Panel $panel -Unselect $true
            }
            elseif ($KeyInfo.KeyChar -eq '*') {
                Invert-Selection -Panel $panel
            }
            elseif (-not [char]::IsControl($KeyInfo.KeyChar)) {
                $script:State.CommandLine += [string]$KeyInfo.KeyChar
            }
        }
    }
}

function Initialize-State {
    $left = New-PanelState -Name 'Left' -Path $LeftPath
    $right = New-PanelState -Name 'Right' -Path $RightPath
    $script:State = @{
        LeftPanel = $left
        RightPanel = $right
        ActivePanel = 'Left'
        CommandLine = ''
        ExitRequested = $false
        VisibleRows = 10
    }
    Refresh-Panel -Panel $script:State.LeftPanel
    Refresh-Panel -Panel $script:State.RightPanel
}

function Start-InteractiveApp {
    try {
        $script:OriginalForeground = [Console]::ForegroundColor
        $script:OriginalBackground = [Console]::BackgroundColor
    }
    catch {
    }

    Initialize-ConsoleInputMode
    Clear-ScreenSafe
    Request-FullRedraw

    try {
        while (-not $script:State.ExitRequested) {
            $size = Get-ConsoleSizeSafe
            $script:State.VisibleRows = [Math]::Max(1, $size.Height - 8)
            Render-App
            try {
                $inputEvent = Read-InputEvent
                if ($inputEvent.Type -eq 'Key') {
                    Handle-Key -KeyInfo $inputEvent.KeyInfo
                }
                elseif ($inputEvent.Type -eq 'Mouse') {
                    Handle-MouseEvent -MouseEvent $inputEvent
                }
                elseif ($inputEvent.Type -eq 'Resize') {
                    Request-FullRedraw
                }
            }
            catch {
                Write-AppLog -Level 'ERROR' -Message ('Interactive loop failed: {0}' -f $_.Exception.Message)
                Show-Message -Message ('Error: {0}' -f $_.Exception.Message)
            }
        }
    }
    finally {
        Restore-ConsoleInputMode
        Reset-ConsoleColorsSafe
        Clear-ScreenSafe
    }
}

function Probe-MouseBackendAvailability {
    param(
        [string]$BackendMode
    )

    $originalMode = [string]$script:Config.MouseMode
    $originalPreference = [string]$script:InputModePreference
    $originalRequested = [string]$script:MouseBackendRequested
    try {
        $script:Config.MouseMode = $BackendMode
        $script:InputModePreference = $BackendMode
        $script:MouseBackendRequested = $BackendMode
        Initialize-ConsoleInputMode
        return @{
            Available = [bool]$script:MouseInputAvailable
            Backend = [string]$script:MouseBackend
            FailureReason = [string]$script:MouseUnavailableReason
        }
    }
    finally {
        Restore-ConsoleInputMode
        $script:Config.MouseMode = $originalMode
        $script:InputModePreference = $originalPreference
        $script:MouseBackendRequested = $originalRequested
    }
}

function Start-MouseDiagnosticsMode {
    $originalMode = [string]$script:Config.MouseMode
    $win32Probe = Probe-MouseBackendAvailability -BackendMode 'Win32'
    $vtProbe = Probe-MouseBackendAvailability -BackendMode 'VT'
    $script:Config.MouseMode = $originalMode
    $script:InputModePreference = $originalMode
    $script:MouseBackendRequested = $originalMode
    Initialize-ConsoleInputMode
    try {
        $script:MouseDiagnosticsState.Win32MouseAvailable = ([bool]$win32Probe.Available -and $win32Probe.Backend -eq 'Win32')
        $script:MouseDiagnosticsState.VtMouseBackendAvailable = ([bool]$vtProbe.Available -and $vtProbe.Backend -eq 'VT')
        $script:MouseDiagnosticsState.VtInputAvailable = $script:MouseDiagnosticsState.VtMouseBackendAvailable
        foreach ($line in (Get-MouseDiagnosticsLines)) {
            Write-Output $line
        }
        Write-Output ''
        Write-Output ('Win32 probe: available={0} backend={1} reason={2}' -f $win32Probe.Available, $win32Probe.Backend, $win32Probe.FailureReason)
        Write-Output ('VT probe: available={0} backend={1} reason={2}' -f $vtProbe.Available, $vtProbe.Backend, $vtProbe.FailureReason)
        Write-Output ''
        Write-Output 'Mouse diagnostics event loop. Press Esc to exit.'
        while ($true) {
            try {
                $event = Read-InputEvent
            }
            catch {
                Write-Output ('Mouse diagnostics stopped: {0}' -f $_.Exception.Message)
                break
            }
            if ($event.Type -eq 'Key') {
                $key = $event.KeyInfo
                Write-Output ('KEY backend={0} key={1} char={2} modifiers={3}' -f $event.Backend, $key.Key, [int][char]$key.KeyChar, $key.Modifiers)
                if ($key.Key -eq [ConsoleKey]::Escape) {
                    break
                }
            }
            elseif ($event.Type -eq 'Mouse') {
                Initialize-MouseEventFields -MouseEvent $event
                Write-Output ('MOUSE backend={0} x={1} y={2} down={3} up={4} click={5} dbl={6} nativeDbl={7} syntheticDbl={8} suppressed={9} zone={10} panel={11} row={12} buttons=0x{13:X8} flags=0x{14:X8} wheel={15}' -f $event.Backend, $event.X, $event.Y, $event.ButtonDown, $event.ButtonUp, $event.Click, $event.DoubleClick, $event.NativeDoubleClick, $event.SyntheticDoubleClick, $event.SuppressedDuplicateClick, $event.ZoneKind, $event.PanelName, $event.RowIndex, $event.ButtonState, $event.EventFlags, $event.WheelDelta)
            }
            elseif ($event.Type -eq 'Resize') {
                Write-Output ('RESIZE backend={0}' -f $event.Backend)
            }
        }
    }
    finally {
        $script:Config.MouseMode = $originalMode
        $script:InputModePreference = $originalMode
        $script:MouseBackendRequested = $originalMode
        Restore-ConsoleInputMode
    }
}

function Test-SelfCondition {
    param(
        [string]$Name,
        [bool]$Condition,
        [System.Collections.ArrayList]$Results
    )

    if ($Condition) {
        [void]$Results.Add(('PASS {0}' -f $Name))
        return $true
    }
    [void]$Results.Add(('FAIL {0}' -f $Name))
    return $false
}

function Invoke-InputParserSelfTestCases {
    param(
        [System.Collections.ArrayList]$Results
    )

    $failed = 0
    $cases = @(
        @{ Name = 'vt key up arrow'; Sequence = '[A'; Key = [System.ConsoleKey]::UpArrow },
        @{ Name = 'vt key down arrow'; Sequence = '[B'; Key = [System.ConsoleKey]::DownArrow },
        @{ Name = 'vt key right arrow'; Sequence = '[C'; Key = [System.ConsoleKey]::RightArrow },
        @{ Name = 'vt key left arrow'; Sequence = '[D'; Key = [System.ConsoleKey]::LeftArrow },
        @{ Name = 'vt key home bracket'; Sequence = '[H'; Key = [System.ConsoleKey]::Home },
        @{ Name = 'vt key end bracket'; Sequence = '[F'; Key = [System.ConsoleKey]::End },
        @{ Name = 'vt key home tilde'; Sequence = '[1~'; Key = [System.ConsoleKey]::Home },
        @{ Name = 'vt key end tilde'; Sequence = '[4~'; Key = [System.ConsoleKey]::End },
        @{ Name = 'vt key page up'; Sequence = '[5~'; Key = [System.ConsoleKey]::PageUp },
        @{ Name = 'vt key page down'; Sequence = '[6~'; Key = [System.ConsoleKey]::PageDown },
        @{ Name = 'vt key delete'; Sequence = '[3~'; Key = [System.ConsoleKey]::Delete },
        @{ Name = 'vt key insert'; Sequence = '[2~'; Key = [System.ConsoleKey]::Insert },
        @{ Name = 'vt key ss3 f1'; Sequence = 'OP'; Key = [System.ConsoleKey]::F1 },
        @{ Name = 'vt key ss3 f2'; Sequence = 'OQ'; Key = [System.ConsoleKey]::F2 },
        @{ Name = 'vt key ss3 f3'; Sequence = 'OR'; Key = [System.ConsoleKey]::F3 },
        @{ Name = 'vt key ss3 f4'; Sequence = 'OS'; Key = [System.ConsoleKey]::F4 },
        @{ Name = 'vt key tilde f1'; Sequence = '[11~'; Key = [System.ConsoleKey]::F1 },
        @{ Name = 'vt key tilde f2'; Sequence = '[12~'; Key = [System.ConsoleKey]::F2 },
        @{ Name = 'vt key tilde f3'; Sequence = '[13~'; Key = [System.ConsoleKey]::F3 },
        @{ Name = 'vt key tilde f4'; Sequence = '[14~'; Key = [System.ConsoleKey]::F4 },
        @{ Name = 'vt key f5'; Sequence = '[15~'; Key = [System.ConsoleKey]::F5 },
        @{ Name = 'vt key f6'; Sequence = '[17~'; Key = [System.ConsoleKey]::F6 },
        @{ Name = 'vt key f7'; Sequence = '[18~'; Key = [System.ConsoleKey]::F7 },
        @{ Name = 'vt key f8'; Sequence = '[19~'; Key = [System.ConsoleKey]::F8 },
        @{ Name = 'vt key f9'; Sequence = '[20~'; Key = [System.ConsoleKey]::F9 },
        @{ Name = 'vt key f10'; Sequence = '[21~'; Key = [System.ConsoleKey]::F10 },
        @{ Name = 'vt key f11'; Sequence = '[23~'; Key = [System.ConsoleKey]::F11 },
        @{ Name = 'vt key f12'; Sequence = '[24~'; Key = [System.ConsoleKey]::F12 }
    )

    foreach ($case in $cases) {
        $ok = $false
        try {
            $info = Try-ConvertVtKeySequence -Sequence ([string]$case.Sequence)
            $ok = ($null -ne $info -and $info.Key -eq $case.Key -and $info.Key.GetType().FullName -eq 'System.ConsoleKey')
        }
        catch {
            $ok = $false
        }
        if (-not (Test-SelfCondition -Name ([string]$case.Name) -Condition $ok -Results $Results)) { $failed++ }
    }

    $modifierOk = $false
    try {
        $modifierInfo = Try-ConvertVtKeySequence -Sequence '[1;5A'
        $modifierOk = ($null -ne $modifierInfo -and $modifierInfo.Key -eq [System.ConsoleKey]::UpArrow -and (($modifierInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and $modifierInfo.Key.GetType().FullName -eq 'System.ConsoleKey')
    }
    catch {
        $modifierOk = $false
    }
    if (-not (Test-SelfCondition -Name 'vt key ctrl modifier does not throw' -Condition $modifierOk -Results $Results)) { $failed++ }

    $shiftModifierOk = $false
    try {
        $shiftInfo = Try-ConvertVtKeySequence -Sequence '[1;2B'
        $shiftModifierOk = ($null -ne $shiftInfo -and $shiftInfo.Key -eq [System.ConsoleKey]::DownArrow -and (($shiftInfo.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) -and $shiftInfo.Key.GetType().FullName -eq 'System.ConsoleKey')
    }
    catch {
        $shiftModifierOk = $false
    }
    if (-not (Test-SelfCondition -Name 'vt key shift modifier does not throw' -Condition $shiftModifierOk -Results $Results)) { $failed++ }

    return $failed
}

function Run-InputParserSelfTest {
    $results = New-Object System.Collections.ArrayList
    $failed = Invoke-InputParserSelfTestCases -Results $results
    foreach ($line in $results) {
        Write-Output $line
    }
    if ($failed -eq 0) {
        Write-Output 'INPUT_PARSER_SELFTEST PASS'
        exit 0
    }
    Write-Output ('INPUT_PARSER_SELFTEST FAIL: {0} failed checks' -f $failed)
    exit 1
}

function Run-SelfTest {
    $results = New-Object System.Collections.ArrayList
    $failed = 0
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('console_commander_selftest_{0}' -f ([Guid]::NewGuid().ToString('N')))
    $oldLocalDataPath = $script:LocalDataPath
    $oldNonInteractiveMode = $script:NonInteractiveMode

    try {
        $script:NonInteractiveMode = $true
        New-DirectoryIfMissing -Path $root
        $script:LocalDataPath = Join-Path -Path $root -ChildPath 'localdata'
        New-DirectoryIfMissing -Path $script:LocalDataPath
        $leftRoot = Join-Path -Path $root -ChildPath 'left'
        $rightRoot = Join-Path -Path $root -ChildPath 'right'
        New-DirectoryIfMissing -Path $leftRoot
        New-DirectoryIfMissing -Path $rightRoot
        New-DirectoryIfMissing -Path (Join-Path -Path $leftRoot -ChildPath 'dirA')
        Set-Content -LiteralPath (Join-Path -Path $leftRoot -ChildPath 'file1.txt') -Value 'alpha content' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path -Path $leftRoot -ChildPath 'dirA\nested.txt') -Value 'nested beta content' -Encoding UTF8 -ErrorAction Stop

        $testPanel = New-PanelState -Name 'Test' -Path $leftRoot
        Refresh-Panel -Panel $testPanel
        if (-not (Test-SelfCondition -Name 'listing' -Condition ($testPanel.Items.Count -ge 3) -Results $results)) { $failed++ }

        $fileItem = $null
        foreach ($item in $testPanel.Items) {
            if ($item.Name -eq 'file1.txt') { $fileItem = $item }
        }
        if (-not (Test-SelfCondition -Name 'find test file in panel' -Condition ($null -ne $fileItem) -Results $results)) { $failed++ }

        if ($null -ne $fileItem) {
            [void](Copy-ItemsToDirectory -Items @($fileItem) -DestinationDirectory $rightRoot -AssumeYes $true)
        }
        if (-not (Test-SelfCondition -Name 'copy file' -Condition (Test-Path -LiteralPath (Join-Path -Path $rightRoot -ChildPath 'file1.txt')) -Results $results)) { $failed++ }

        $copyOverwriteSource = Join-Path -Path $leftRoot -ChildPath 'copy_overwrite_source.txt'
        $copyOverwriteDest = Join-Path -Path $rightRoot -ChildPath 'copy_overwrite_dest.txt'
        Set-Content -LiteralPath $copyOverwriteSource -Value 'copy overwrite new' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $copyOverwriteDest -Value 'copy overwrite old' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $copyOverwriteResult = Copy-FileSafe -Source $copyOverwriteSource -Destination $copyOverwriteDest -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true
        $copyOverwriteText = Get-Content -LiteralPath $copyOverwriteDest -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'safe copy overwrite existing file' -Condition ($copyOverwriteResult -eq 'Copied' -and $copyOverwriteText -like '*copy overwrite new*' -and (Test-Path -LiteralPath $copyOverwriteSource)) -Results $results)) { $failed++ }

        $copyRollbackSource = Join-Path -Path $leftRoot -ChildPath 'copy_rollback_source.txt'
        $copyRollbackDest = Join-Path -Path $rightRoot -ChildPath 'copy_rollback_dest.txt'
        Set-Content -LiteralPath $copyRollbackSource -Value 'copy rollback new' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $copyRollbackDest -Value 'copy rollback old' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $copyRollbackResult = Copy-FileSafe -Source $copyRollbackSource -Destination $copyRollbackDest -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true -SimulateFailureAfterBackup
        $copyRollbackText = Get-Content -LiteralPath $copyRollbackDest -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'failed copy preserves destination' -Condition ($copyRollbackResult -eq 'Error' -and $copyRollbackText -like '*copy rollback old*' -and (Test-Path -LiteralPath $copyRollbackSource)) -Results $results)) { $failed++ }

        $dirItem = $null
        foreach ($item in $testPanel.Items) {
            if ($item.Name -eq 'dirA') { $dirItem = $item }
        }
        if ($null -ne $dirItem) {
            [void](Copy-ItemsToDirectory -Items @($dirItem) -DestinationDirectory $rightRoot -AssumeYes $true)
        }
        if (-not (Test-SelfCondition -Name 'copy directory recursive' -Condition (Test-Path -LiteralPath (Join-Path -Path $rightRoot -ChildPath 'dirA\nested.txt')) -Results $results)) { $failed++ }

        $moveSource = Join-Path -Path $rightRoot -ChildPath 'file1.txt'
        $moveDest = Join-Path -Path $rightRoot -ChildPath 'renamed.txt'
        $overwritePolicy = 'Ask'
        [void](Move-PathSafe -Source $moveSource -Destination $moveDest -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true)
        if (-not (Test-SelfCondition -Name 'move rename' -Condition (Test-Path -LiteralPath $moveDest) -Results $results)) { $failed++ }

        $overwriteSource = Join-Path -Path $rightRoot -ChildPath 'overwrite_source.txt'
        $overwriteDest = Join-Path -Path $rightRoot -ChildPath 'overwrite_dest.txt'
        Set-Content -LiteralPath $overwriteSource -Value 'new overwrite content' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $overwriteDest -Value 'old overwrite content' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $overwriteResult = Move-PathSafe -Source $overwriteSource -Destination $overwriteDest -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true
        $overwriteText = Get-Content -LiteralPath $overwriteDest -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'safe move overwrite existing file' -Condition ($overwriteResult -eq 'Moved' -and $overwriteText -like '*new overwrite content*' -and -not (Test-Path -LiteralPath $overwriteSource)) -Results $results)) { $failed++ }

        $rollbackSource = Join-Path -Path $rightRoot -ChildPath 'rollback_source.txt'
        $rollbackDest = Join-Path -Path $rightRoot -ChildPath 'rollback_dest.txt'
        Set-Content -LiteralPath $rollbackSource -Value 'rollback new' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $rollbackDest -Value 'rollback old' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $rollbackResult = Move-PathSafe -Source $rollbackSource -Destination $rollbackDest -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true -SimulateFailureAfterBackup
        $rollbackText = Get-Content -LiteralPath $rollbackDest -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'failed move preserves destination' -Condition ($rollbackResult -eq 'Error' -and $rollbackText -like '*rollback old*' -and (Test-Path -LiteralPath $rollbackSource)) -Results $results)) { $failed++ }

        $fallbackSource = Join-Path -Path $rightRoot -ChildPath 'fallback_source.txt'
        $fallbackDest = Join-Path -Path $rightRoot -ChildPath 'fallback_dest.txt'
        Set-Content -LiteralPath $fallbackSource -Value 'fallback new' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $fallbackDest -Value 'fallback old' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $fallbackResult = Move-PathSafe -Source $fallbackSource -Destination $fallbackDest -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true -ForceCopyFallback $true
        $fallbackText = Get-Content -LiteralPath $fallbackDest -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'forced copy-delete move fallback' -Condition ($fallbackResult -eq 'Moved' -and $fallbackText -like '*fallback new*' -and -not (Test-Path -LiteralPath $fallbackSource)) -Results $results)) { $failed++ }

        $samePathMove = Join-Path -Path $rightRoot -ChildPath 'same_path_move.txt'
        Set-Content -LiteralPath $samePathMove -Value 'same path stays' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $samePathResult = Move-PathSafe -Source $samePathMove -Destination $samePathMove -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true
        $samePathText = Get-Content -LiteralPath $samePathMove -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'same path move is no-op' -Condition ($samePathResult -eq 'Skipped' -and $samePathText -like '*same path stays*') -Results $results)) { $failed++ }

        [void](New-DirectorySafe -ParentPath $rightRoot -Name 'made')
        if (-not (Test-SelfCondition -Name 'mkdir' -Condition (Test-Path -LiteralPath (Join-Path -Path $rightRoot -ChildPath 'made')) -Results $results)) { $failed++ }

        $deletePath = Join-Path -Path $rightRoot -ChildPath 'delete_me.txt'
        Set-Content -LiteralPath $deletePath -Value 'delete' -Encoding UTF8 -ErrorAction Stop
        $deleteInfo = Get-Item -LiteralPath $deletePath -Force -ErrorAction Stop
        $deleteItem = New-FileItem -Name $deleteInfo.Name -FullName $deleteInfo.FullName -IsDirectory $false -Length $deleteInfo.Length -LastWriteTime $deleteInfo.LastWriteTime -Attributes $deleteInfo.Attributes
        [void](Delete-ItemsSafe -Items @($deleteItem) -AssumeYes $true)
        if (-not (Test-SelfCondition -Name 'delete' -Condition (-not (Test-Path -LiteralPath $deletePath)) -Results $results)) { $failed++ }

        $oldSafeDelete = $script:Config.SafeDelete
        $script:Config.SafeDelete = $true
        $safeDeletePath = Join-Path -Path $rightRoot -ChildPath 'safe_delete_meta.txt'
        Set-Content -LiteralPath $safeDeletePath -Value 'trash metadata' -Encoding UTF8 -ErrorAction Stop
        $safeDeleteInfo = Get-Item -LiteralPath $safeDeletePath -Force -ErrorAction Stop
        $safeDeleteItem = New-FileItem -Name $safeDeleteInfo.Name -FullName $safeDeleteInfo.FullName -IsDirectory $false -Length $safeDeleteInfo.Length -LastWriteTime $safeDeleteInfo.LastWriteTime -Attributes $safeDeleteInfo.Attributes
        [void](Delete-ItemsSafe -Items @($safeDeleteItem) -AssumeYes $true)
        $trashMetadata = @(Get-TrashMetadataItems | Where-Object { $_.OriginalPath -eq $safeDeletePath })
        if (-not (Test-SelfCondition -Name 'safe delete metadata' -Condition ($trashMetadata.Count -ge 1 -and -not (Test-Path -LiteralPath $safeDeletePath)) -Results $results)) { $failed++ }
        $script:Config.SafeDelete = $oldSafeDelete

        $nameResults = @(Search-FilesInternal -StartPath $leftRoot -NamePattern '*.txt')
        if (-not (Test-SelfCondition -Name 'search by filename' -Condition ($nameResults.Count -ge 2) -Results $results)) { $failed++ }

        $contentResults = @(Search-FilesInternal -StartPath $leftRoot -NamePattern '*.txt' -ContentPattern 'beta')
        if (-not (Test-SelfCondition -Name 'content search' -Condition ($contentResults.Count -ge 1) -Results $results)) { $failed++ }

        $wholeWordPath = Join-Path -Path $leftRoot -ChildPath 'whole_word.txt'
        $partialWordPath = Join-Path -Path $leftRoot -ChildPath 'partial_word.txt'
        Set-Content -LiteralPath $wholeWordPath -Value 'alpha beta gamma' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $partialWordPath -Value 'alphabetagamma' -Encoding UTF8 -ErrorAction Stop
        $wholeWordResults = @(Search-FilesInternal -StartPath $leftRoot -NamePattern '*word.txt' -ContentPattern 'bet[a]' -ContentRegex $true -WholeWord $true)
        $wholeWordOk = (@($wholeWordResults | Where-Object { $_.FullName -eq $wholeWordPath }).Count -eq 1 -and @($wholeWordResults | Where-Object { $_.FullName -eq $partialWordPath }).Count -eq 0)
        if (-not (Test-SelfCondition -Name 'content regex whole-word search' -Condition $wholeWordOk -Results $results)) { $failed++ }

        $largePath = Join-Path -Path $root -ChildPath 'large.bin'
        $fs = [System.IO.File]::Open($largePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            $fs.SetLength(2097152)
        }
        finally {
            $fs.Dispose()
        }
        $prefixBytes = Read-FilePrefixBytes -Path $largePath -MaxBytes 1048576
        if (-not (Test-SelfCondition -Name 'large binary prefix read' -Condition ($prefixBytes.Length -eq 1048576) -Results $results)) { $failed++ }

        $dangerPath = Join-Path -Path $leftRoot -ChildPath "danger & (x) % ! ' space.txt"
        Set-Content -LiteralPath $dangerPath -Value 'danger' -Encoding UTF8 -ErrorAction Stop
        $dangerInfo = Get-Item -LiteralPath $dangerPath -Force -ErrorAction Stop
        $dangerItem = New-FileItem -Name $dangerInfo.Name -FullName $dangerInfo.FullName -IsDirectory $false -Length $dangerInfo.Length -LastWriteTime $dangerInfo.LastWriteTime -Attributes $dangerInfo.Attributes
        $expandedCommand = Expand-CommandMacros -Command 'echo %s' -Items @($dangerItem)
        $macroOk = ($expandedCommand -like '*^&*' -and $expandedCommand -like '*^(*' -and $expandedCommand -like '*^%*' -and $expandedCommand -like '*^!*' -and $script:LastCommandMacroEnvironment.CC_SELECTED_PATHS -eq $dangerPath)
        if (-not (Test-SelfCondition -Name 'command macro quoting dangerous filename' -Condition $macroOk -Results $results)) { $failed++ }
        $singleQuoted = Quote-PowerShellSingleQuotedString -Value "O'Hara & Sons"
        if (-not (Test-SelfCondition -Name 'powershell single quote escaping' -Condition ($singleQuoted -eq "'O''Hara & Sons'") -Results $results)) { $failed++ }

        $refusedCommand = Invoke-CommandLineSafe -CommandLine 'powershell.exe -NoExit' -WorkingDirectory $leftRoot
        if (-not (Test-SelfCondition -Name 'interactive command refused' -Condition ([string]::Join(' ', [string[]]$refusedCommand) -like '*Command refused*') -Results $results)) { $failed++ }
        $largeCommand = 'powershell.exe -NoProfile -Command "1..50 | ForEach-Object { Write-Output (''out'' + $_); [Console]::Error.WriteLine((''err'' + $_)) }"'
        $largeCommandOutput = Invoke-CommandLineSafe -CommandLine $largeCommand -WorkingDirectory $leftRoot
        $largeCommandText = [string]::Join("`n", [string[]]$largeCommandOutput)
        if (-not (Test-SelfCondition -Name 'dual stream command output' -Condition ($largeCommandText -like '*out50*' -and $largeCommandText -like '*err50*') -Results $results)) { $failed++ }

        $oldConfirmCopy = $script:Config.ConfirmCopy
        $script:Config.ConfirmCopy = $false
        $confirmFlagDest = Join-Path -Path $root -ChildPath 'confirm_flag'
        New-DirectoryIfMissing -Path $confirmFlagDest
        [void](Copy-ItemsToDirectory -Items @($dangerItem) -DestinationDirectory $confirmFlagDest -AssumeYes $false)
        if (-not (Test-SelfCondition -Name 'confirm copy flag honored' -Condition (Test-Path -LiteralPath (Join-Path -Path $confirmFlagDest -ChildPath $dangerItem.Name)) -Results $results)) { $failed++ }
        $script:Config.ConfirmCopy = $oldConfirmCopy

        $filterPanel = New-PanelState -Name 'Filter' -Path $leftRoot
        $filterPanel.FilterPattern = '*.txt'
        $filterPanel.FilterRegex = $false
        Refresh-Panel -Panel $filterPanel
        $wildcardFilterOk = $true
        foreach ($filterItem in $filterPanel.Items) {
            if (-not $filterItem.IsParent -and $filterItem.Name -notlike '*.txt') {
                $wildcardFilterOk = $false
            }
        }
        if (-not (Test-SelfCondition -Name 'wildcard panel filter' -Condition $wildcardFilterOk -Results $results)) { $failed++ }
        $filterPanel.FilterPattern = '^file1\.txt$'
        $filterPanel.FilterRegex = $true
        Refresh-Panel -Panel $filterPanel
        $regexFilterOk = (@($filterPanel.Items | Where-Object { -not $_.IsParent -and $_.Name -eq 'file1.txt' }).Count -eq 1)
        if (-not (Test-SelfCondition -Name 'regex panel filter' -Condition $regexFilterOk -Results $results)) { $failed++ }

        $historyA = Join-Path -Path $root -ChildPath 'history_a'
        $historyB = Join-Path -Path $root -ChildPath 'history_b'
        New-DirectoryIfMissing -Path $historyA
        New-DirectoryIfMissing -Path $historyB
        $historyPanel = New-PanelState -Name 'History' -Path $historyA
        [void](Set-PanelLocalPath -Panel $historyPanel -Path $historyB)
        [void](Move-PanelHistory -Panel $historyPanel -Delta -1)
        $historyBackOk = ($historyPanel.Path -eq (Get-NormalizedPath -Path $historyA) -and $historyPanel.History.Count -eq 2)
        [void](Move-PanelHistory -Panel $historyPanel -Delta 1)
        $historyForwardOk = ($historyPanel.Path -eq (Get-NormalizedPath -Path $historyB) -and $historyPanel.History.Count -eq 2)
        if (-not (Test-SelfCondition -Name 'panel history back forward' -Condition ($historyBackOk -and $historyForwardOk) -Results $results)) { $failed++ }

        $oldEditorTabSize = $script:Config.EditorTabSize
        $script:Config.EditorTabSize = 3
        $tabText = Get-EditorTabText
        $script:Config.EditorTabSize = $oldEditorTabSize
        if (-not (Test-SelfCondition -Name 'editor tab insert size' -Condition ($tabText.Length -eq 3) -Results $results)) { $failed++ }

        $layout = Get-ConsoleCommanderLayout -Width 80 -Height 25
        $layoutOk = ($layout.TopMenuRow -eq 0 -and $layout.CommandLineRow -eq 23 -and $layout.FunctionKeyRow -eq 24 -and $layout.UsableFileListHeight -gt 0)
        if (-not (Test-SelfCondition -Name 'tui layout calculator' -Condition $layoutOk -Results $results)) { $failed++ }

        $oldOwnerName = $script:Config.OwnerName
        $oldOwnerEmail = $script:Config.OwnerEmail
        try {
            $script:Config.OwnerName = 'Zolnai Zsolt'
            $script:Config.OwnerEmail = 'zzsolt@gmail.com'
            $wideLines = Build-AppScreenLines -Width 140 -Height 30
            $wideTopBarText = Convert-RenderLineToPlainText -Line $wideLines[0]
            $narrowLines = Build-AppScreenLines -Width 80 -Height 25
            $narrowTopBarText = Convert-RenderLineToPlainText -Line $narrowLines[0]
            $aboutText = [string]::Join("`n", [string[]](Get-AboutLines))
            $helpText = [string]::Join("`n", [string[]](Get-HelpLines))
            $ownerMetadataOk = (
                $wideTopBarText -like '*Owner: Zolnai Zsolt <zzsolt@gmail.com>*' -and
                $wideTopBarText -like '*Input:*' -and
                $narrowTopBarText -like '*Zolnai Zsolt*' -and
                $aboutText -like '*Version: 0.7.0*' -and
                $aboutText -like '*Repository: https://github.com/zzsolt/console_commander*' -and
                $helpText -like '*Email: zzsolt@gmail.com*'
            )
            if (-not (Test-SelfCondition -Name 'owner metadata topbar about help' -Condition $ownerMetadataOk -Results $results)) { $failed++ }
        }
        finally {
            $script:Config.OwnerName = $oldOwnerName
            $script:Config.OwnerEmail = $oldOwnerEmail
        }

        $oldBorderStyle = $script:Config.BorderStyle
        $script:Config.BorderStyle = 'ASCII'
        $script:Config.UseAscii = $true
        Initialize-UiTheme
        $asciiBorderOk = ((Get-BorderCharacters).TDown -eq '+')
        $script:Config.BorderStyle = $oldBorderStyle
        Initialize-UiTheme
        if (-not (Test-SelfCondition -Name 'ascii border theme' -Condition $asciiBorderOk -Results $results)) { $failed++ }

        $dropdownTopText = Convert-CharArrayToString -Characters ([char[]]@([char]'+', [char]'-', [char]'-', [char]'+'))
        if (-not (Test-SelfCondition -Name 'dropdown char array string conversion' -Condition ($dropdownTopText -eq '+--+') -Results $results)) { $failed++ }

        $zeroVirtualKey = Convert-VirtualKeyCodeToConsoleKey -VirtualKeyCode 0 -KeyChar ([char]'x')
        $fallbackKeyInfo = New-ConsoleKeyInfoFromCharacter -Character ([char]'0')
        $punctuationKeyInfo = New-ConsoleKeyInfoFromCharacter -Character ([char]'[')
        $vtFallbackOk = ($zeroVirtualKey -eq [ConsoleKey]::X -and $fallbackKeyInfo.Key -eq [ConsoleKey]::D0 -and $punctuationKeyInfo.Key -eq [ConsoleKey]::Oem4)
        if (-not (Test-SelfCondition -Name 'vt fallback key conversion' -Condition $vtFallbackOk -Results $results)) { $failed++ }

        $failed += Invoke-InputParserSelfTestCases -Results $results

        $rawCrInfo = New-SafeConsoleKeyInfo -KeyChar ([char]13) -Key ([System.ConsoleKey]::Spacebar)
        $rawLfInfo = New-SafeConsoleKeyInfo -KeyChar ([char]10) -Key ([System.ConsoleKey]::Spacebar)
        $normalizedCr = Normalize-ConsoleKeyInfo -KeyInfo $rawCrInfo
        $normalizedLf = Normalize-ConsoleKeyInfo -KeyInfo $rawLfInfo
        $enterNormalizeOk = ($normalizedCr.Key -eq [System.ConsoleKey]::Enter -and $normalizedLf.Key -eq [System.ConsoleKey]::Enter -and [int][char]$normalizedCr.KeyChar -eq 13 -and [int][char]$normalizedLf.KeyChar -eq 13)
        if (-not (Test-SelfCondition -Name 'enter key normalization cr lf' -Condition $enterNormalizeOk -Results $results)) { $failed++ }

        $oldStateForInputTests = $script:State
        $oldLastCommandOutput = $script:LastCommandLineOutput
        try {
            $enterChild = Join-Path -Path $leftRoot -ChildPath 'enter_child'
            New-DirectoryIfMissing -Path $enterChild
            $enterLeft = New-PanelState -Name 'EnterLeft' -Path $leftRoot
            $enterRight = New-PanelState -Name 'EnterRight' -Path $rightRoot
            Refresh-Panel -Panel $enterLeft
            Refresh-Panel -Panel $enterRight
            $script:State = @{
                LeftPanel = $enterLeft
                RightPanel = $enterRight
                ActivePanel = 'Left'
                CommandLine = ''
                ExitRequested = $false
                VisibleRows = 10
            }
            $enterIndex = -1
            for ($i = 0; $i -lt $enterLeft.Items.Count; $i++) {
                if ($enterLeft.Items[$i].Name -eq 'enter_child') {
                    $enterIndex = $i
                    break
                }
            }
            if ($enterIndex -ge 0) {
                Set-SelectionAbsolute -Panel $enterLeft -Index $enterIndex -VisibleRows 10
                Handle-Key -KeyInfo (Normalize-ConsoleKeyInfo -KeyInfo $rawCrInfo)
            }
            $enterCurrentItemOk = ($enterIndex -ge 0 -and $script:State.LeftPanel.Path -eq (Get-NormalizedPath -Path $enterChild))
            if (-not (Test-SelfCondition -Name 'enter key opens selected directory' -Condition $enterCurrentItemOk -Results $results)) { $failed++ }

            $commandLeft = New-PanelState -Name 'CommandLeft' -Path $leftRoot
            $commandRight = New-PanelState -Name 'CommandRight' -Path $rightRoot
            Refresh-Panel -Panel $commandLeft
            Refresh-Panel -Panel $commandRight
            $script:State = @{
                LeftPanel = $commandLeft
                RightPanel = $commandRight
                ActivePanel = 'Left'
                CommandLine = 'cmd.exe /c echo cc_enter_command'
                ExitRequested = $false
                VisibleRows = 10
            }
            $script:LastCommandLineOutput = @()
            Handle-Key -KeyInfo (Normalize-ConsoleKeyInfo -KeyInfo $rawLfInfo)
            $commandOutputText = [string]::Join("`n", [string[]]$script:LastCommandLineOutput)
            $enterCommandOk = ($script:State.CommandLine -eq '' -and $commandOutputText -like '*cc_enter_command*')
            if (-not (Test-SelfCondition -Name 'enter key runs typed command' -Condition $enterCommandOk -Results $results)) { $failed++ }

            $script:State.CommandLine = 'typed'
            $screenLines = Build-AppScreenLines -Width 120 -Height 30
            $layoutForCommand = $script:RenderState.LastLayout
            $commandLineText = Convert-RenderLineToPlainText -Line $screenLines[$layoutForCommand.CommandLineRow]
            $commandRowOk = ($layoutForCommand.CommandLineRow -eq ($layoutForCommand.FunctionKeyRow - 1) -and $layoutForCommand.CommandLineRow -gt $layoutForCommand.BottomBorderRow -and $layoutForCommand.CommandLineRow -ne $layoutForCommand.FunctionKeyRow -and $commandLineText -like '*Cmd:*' -and $commandLineText -like '*>*')
            if (-not (Test-SelfCondition -Name 'command row visible and separated' -Condition $commandRowOk -Results $results)) { $failed++ }
        }
        finally {
            $script:State = $oldStateForInputTests
            $script:LastCommandLineOutput = $oldLastCommandOutput
        }

        $oldLastMouseClick = $script:LastMouseClick
        $oldMouseClickSequence = $script:MouseClickSequence
        $oldStateForMouseTests = $script:State
        try {
            $mouseDirA = Join-Path -Path $leftRoot -ChildPath 'mouse_dir_a'
            $mouseDirB = Join-Path -Path $leftRoot -ChildPath 'mouse_dir_b'
            $mouseRightDir = Join-Path -Path $rightRoot -ChildPath 'mouse_right_dir'
            New-DirectoryIfMissing -Path $mouseDirA
            New-DirectoryIfMissing -Path $mouseDirB
            New-DirectoryIfMissing -Path $mouseRightDir

            $mouseLeft = New-PanelState -Name 'MouseLeft' -Path $leftRoot
            $mouseRight = New-PanelState -Name 'MouseRight' -Path $rightRoot
            Refresh-Panel -Panel $mouseLeft
            Refresh-Panel -Panel $mouseRight
            $script:State = @{
                LeftPanel = $mouseLeft
                RightPanel = $mouseRight
                ActivePanel = 'Left'
                CommandLine = ''
                ExitRequested = $false
                VisibleRows = 10
            }
            [void](Build-AppScreenLines -Width 120 -Height 30)
            $script:State.VisibleRows = $script:RenderState.LeftPanelZone.VisibleRows
            $leftZone = $script:RenderState.LeftPanelZone
            $rightZone = $script:RenderState.RightPanelZone

            $mouseIndexA = -1
            $mouseIndexB = -1
            for ($i = 0; $i -lt $mouseLeft.Items.Count; $i++) {
                if ($mouseLeft.Items[$i].Name -eq 'mouse_dir_a') { $mouseIndexA = $i }
                if ($mouseLeft.Items[$i].Name -eq 'mouse_dir_b') { $mouseIndexB = $i }
            }
            $rightIndex = -1
            for ($i = 0; $i -lt $mouseRight.Items.Count; $i++) {
                if ($mouseRight.Items[$i].Name -eq 'mouse_right_dir') { $rightIndex = $i }
            }

            $mouseRowA = $mouseIndexA - $mouseLeft.TopIndex
            $mouseRowB = $mouseIndexB - $mouseLeft.TopIndex
            $rightRow = $rightIndex - $mouseRight.TopIndex
            $mouseXA = [int]$leftZone.Left + 2
            $mouseYA = [int]$leftZone.RowTop + $mouseRowA
            $mouseYB = [int]$leftZone.RowTop + $mouseRowB
            $mouseXR = [int]$rightZone.Left + 2
            $mouseYR = [int]$rightZone.RowTop + $rightRow
            $mouseCoordinatesOk = ($mouseIndexA -ge 0 -and $mouseIndexB -ge 0 -and $rightIndex -ge 0 -and $mouseRowA -ge 0 -and $mouseRowB -ge 0 -and $rightRow -ge 0)

            $script:LastMouseClick = $null
            $singleEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYA -ButtonState ([uint32]0) -ButtonDown $true -Click $true -Backend 'VT'
            Handle-MouseEvent -MouseEvent $singleEvent
            $singleClickOk = ($mouseCoordinatesOk -and $script:State.ActivePanel -eq 'Left' -and $script:State.LeftPanel.SelectedIndex -eq $mouseIndexA -and $script:State.LeftPanel.Path -eq (Get-NormalizedPath -Path $leftRoot) -and [string]$singleEvent.ActionTaken -eq 'SelectOnly')
            if (-not (Test-SelfCondition -Name 'mouse single click selects only' -Condition $singleClickOk -Results $results)) { $failed++ }

            $script:LastMouseClick = $null
            $downEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYA -ButtonState ([uint32]0) -ButtonDown $true -Click $true -Backend 'VT'
            Handle-MouseEvent -MouseEvent $downEvent
            $upEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYA -ButtonState ([uint32]0) -ButtonUp $true -Click $false -Backend 'VT'
            Handle-MouseEvent -MouseEvent $upEvent
            $buttonUpOk = (-not [bool]$upEvent.DoubleClick -and [string]$upEvent.ActionTaken -eq 'Ignored' -and $script:State.LeftPanel.Path -eq (Get-NormalizedPath -Path $leftRoot))
            if (-not (Test-SelfCondition -Name 'mouse button up does not enter' -Condition $buttonUpOk -Results $results)) { $failed++ }

            $script:State.LeftPanel = $mouseLeft
            $script:State.ActivePanel = 'Left'
            $script:LastMouseClick = [pscustomobject]@{ X = $mouseXA; Y = $mouseYA; Button = 1; Time = (Get-Date).AddMilliseconds(-200); ZoneKind = 'PanelRow'; PanelName = 'Left'; RowIndex = $mouseIndexA }
            $doubleEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYA -ButtonState ([uint32]0) -ButtonDown $true -Click $true -Backend 'VT'
            Handle-MouseEvent -MouseEvent $doubleEvent
            $doubleClickOk = ([bool]$doubleEvent.DoubleClick -and [bool]$doubleEvent.SyntheticDoubleClick -and [string]$doubleEvent.ActionTaken -eq 'EnterCurrentItem' -and $script:State.LeftPanel.Path -eq (Get-NormalizedPath -Path $mouseDirA))
            if (-not (Test-SelfCondition -Name 'mouse double click enters selected row' -Condition $doubleClickOk -Results $results)) { $failed++ }

            $mouseLeft = New-PanelState -Name 'MouseLeft' -Path $leftRoot
            Refresh-Panel -Panel $mouseLeft
            $script:State.LeftPanel = $mouseLeft
            $script:State.ActivePanel = 'Left'
            $script:LastMouseClick = [pscustomobject]@{ X = $mouseXA; Y = $mouseYA; Button = 1; Time = (Get-Date).AddMilliseconds(-20); ZoneKind = 'PanelRow'; PanelName = 'Left'; RowIndex = $mouseIndexA }
            $duplicateEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYA -ButtonState ([uint32]0) -ButtonDown $true -Click $true -Backend 'VT'
            Handle-MouseEvent -MouseEvent $duplicateEvent
            $duplicateSuppressOk = ([bool]$duplicateEvent.SuppressedDuplicateClick -and -not [bool]$duplicateEvent.DoubleClick -and [string]$duplicateEvent.ActionTaken -eq 'Ignored' -and $script:State.LeftPanel.Path -eq (Get-NormalizedPath -Path $leftRoot))
            if (-not (Test-SelfCondition -Name 'mouse duplicate click suppression' -Condition $duplicateSuppressOk -Results $results)) { $failed++ }

            $script:LastMouseClick = [pscustomobject]@{ X = $mouseXA; Y = $mouseYA; Button = 1; Time = (Get-Date).AddMilliseconds(-200); ZoneKind = 'PanelRow'; PanelName = 'Left'; RowIndex = $mouseIndexA }
            $differentRowEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYB -ButtonState ([uint32]0) -ButtonDown $true -Click $true -Backend 'VT'
            Handle-MouseEvent -MouseEvent $differentRowEvent
            $differentRowOk = (-not [bool]$differentRowEvent.DoubleClick -and [string]$differentRowEvent.ActionTaken -eq 'SelectOnly' -and $script:State.LeftPanel.SelectedIndex -eq $mouseIndexB -and $script:State.LeftPanel.Path -eq (Get-NormalizedPath -Path $leftRoot))
            if (-not (Test-SelfCondition -Name 'mouse different row selects only' -Condition $differentRowOk -Results $results)) { $failed++ }

            $script:LastMouseClick = [pscustomobject]@{ X = $mouseXA; Y = $mouseYA; Button = 1; Time = (Get-Date).AddMilliseconds(-200); ZoneKind = 'PanelRow'; PanelName = 'Left'; RowIndex = $mouseIndexA }
            $differentPanelEvent = New-InputMouseEvent -X $mouseXR -Y $mouseYR -ButtonState ([uint32]0) -ButtonDown $true -Click $true -Backend 'VT'
            Handle-MouseEvent -MouseEvent $differentPanelEvent
            $differentPanelOk = (-not [bool]$differentPanelEvent.DoubleClick -and [string]$differentPanelEvent.ActionTaken -eq 'SelectOnly' -and $script:State.ActivePanel -eq 'Right' -and $script:State.RightPanel.SelectedIndex -eq $rightIndex -and $script:State.RightPanel.Path -eq (Get-NormalizedPath -Path $rightRoot))
            if (-not (Test-SelfCondition -Name 'mouse different panel selects only' -Condition $differentPanelOk -Results $results)) { $failed++ }

            $script:State.ActivePanel = 'Left'
            $script:LastMouseClick = [pscustomobject]@{ X = $mouseXA; Y = $mouseYA; Button = 1; Time = (Get-Date).AddMilliseconds(-200); ZoneKind = 'PanelRow'; PanelName = 'Left'; RowIndex = $mouseIndexA }
            $wheelEvent = New-InputMouseEvent -X $mouseXA -Y $mouseYA -ButtonState ([uint32]64) -WheelDelta 120 -Backend 'VT'
            Handle-MouseEvent -MouseEvent $wheelEvent
            $wheelOk = (-not [bool]$wheelEvent.Click -and -not [bool]$wheelEvent.DoubleClick -and [string]$wheelEvent.ActionTaken -eq 'Ignored' -and $null -eq $script:LastMouseClick)
            if (-not (Test-SelfCondition -Name 'mouse wheel is not click' -Condition $wheelOk -Results $results)) { $failed++ }

            $vtReleaseEvent = Try-ConvertVtMouseSequence -Sequence '[<0;10;5m'
            $vtReleaseOk = ($null -ne $vtReleaseEvent -and [bool]$vtReleaseEvent.ButtonUp -and -not [bool]$vtReleaseEvent.Click -and -not [bool]$vtReleaseEvent.DoubleClick)
            if (-not (Test-SelfCondition -Name 'vt release is not click' -Condition $vtReleaseOk -Results $results)) { $failed++ }
        }
        finally {
            $script:LastMouseClick = $oldLastMouseClick
            $script:MouseClickSequence = $oldMouseClickSequence
            $script:State = $oldStateForMouseTests
        }

        $oldMousePreference = $script:InputModePreference
        $oldMouseRequested = $script:MouseBackendRequested
        $oldMouseBackend = $script:MouseBackend
        $oldMouseAvailable = $script:MouseInputAvailable
        $oldMouseReason = $script:MouseUnavailableReason
        $script:InputModePreference = 'Disabled'
        $script:MouseBackendRequested = 'Disabled'
        $script:MouseInputAvailable = $false
        $script:MouseUnavailableReason = ''
        $keyboardStatusOk = ((Get-InputStatusText) -eq 'Input: Keyboard only - VT off')
        $script:InputModePreference = 'Win32'
        $script:MouseBackendRequested = 'Win32'
        $script:MouseInputAvailable = $false
        $script:MouseUnavailableReason = 'test unavailable'
        $unavailableStatusOk = ((Get-InputStatusText) -eq 'Input: Keyboard only - Win32 unavailable')
        $script:MouseInputAvailable = $true
        $script:MouseBackend = 'VT'
        $combinedStatusOk = ((Get-InputStatusText) -eq 'Input: KB+Mouse VT')
        $script:InputModePreference = $oldMousePreference
        $script:MouseBackendRequested = $oldMouseRequested
        $script:MouseBackend = $oldMouseBackend
        $script:MouseInputAvailable = $oldMouseAvailable
        $script:MouseUnavailableReason = $oldMouseReason
        if (-not (Test-SelfCondition -Name 'input status model' -Condition ($keyboardStatusOk -and $unavailableStatusOk -and $combinedStatusOk) -Results $results)) { $failed++ }

        $compareLeft = Join-Path -Path $root -ChildPath 'compare_left'
        $compareRight = Join-Path -Path $root -ChildPath 'compare_right'
        New-DirectoryIfMissing -Path $compareLeft
        New-DirectoryIfMissing -Path $compareRight
        Set-Content -LiteralPath (Join-Path -Path $compareLeft -ChildPath 'left_only.txt') -Value 'left' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path -Path $compareRight -ChildPath 'right_only.txt') -Value 'right' -Encoding UTF8 -ErrorAction Stop
        $leftMap = Get-DirectoryCompareMap -RootPath $compareLeft -Recursive $false
        $rightMap = Get-DirectoryCompareMap -RootPath $compareRight -Recursive $false
        if (-not (Test-SelfCondition -Name 'directory compare two-way map support' -Condition ($leftMap.ContainsKey('left_only.txt') -and $rightMap.ContainsKey('right_only.txt')) -Results $results)) { $failed++ }

        $zipPath = Join-Path -Path $root -ChildPath 'test.zip'
        [void](New-ZipFromPaths -Paths @((Join-Path -Path $leftRoot -ChildPath 'file1.txt'), (Join-Path -Path $leftRoot -ChildPath 'dirA')) -ZipPath $zipPath -BasePath $leftRoot -AssumeYes $true)
        if (-not (Test-SelfCondition -Name 'zip create' -Condition (Test-Path -LiteralPath $zipPath) -Results $results)) { $failed++ }

        [void](New-ZipFromPaths -Paths @($dangerPath) -ZipPath $zipPath -BasePath $leftRoot -AssumeYes $true)
        $zipOverwriteOk = $false
        $zipCheck = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $zipCheck.Entries) {
                if ($entry.FullName -like '*danger*') { $zipOverwriteOk = $true }
            }
        }
        finally {
            $zipCheck.Dispose()
        }
        if (-not (Test-SelfCondition -Name 'safe zip overwrite create' -Condition $zipOverwriteOk -Results $results)) { $failed++ }

        $extractPath = Join-Path -Path $root -ChildPath 'extract'
        [void](Expand-ZipSafe -ZipPath $zipPath -DestinationPath $extractPath -AssumeYes $true)
        if (-not (Test-SelfCondition -Name 'zip extract' -Condition (Test-Path -LiteralPath (Join-Path -Path $extractPath -ChildPath $dangerItem.Name)) -Results $results)) { $failed++ }

        Set-Content -LiteralPath (Join-Path -Path $extractPath -ChildPath $dangerItem.Name) -Value 'old extracted content' -Encoding UTF8 -ErrorAction Stop
        [void](Expand-ZipSafe -ZipPath $zipPath -DestinationPath $extractPath -AssumeYes $true)
        $zipExtractOverwriteText = Get-Content -LiteralPath (Join-Path -Path $extractPath -ChildPath $dangerItem.Name) -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'safe zip extract overwrite' -Condition ($zipExtractOverwriteText -like '*danger*') -Results $results)) { $failed++ }

        $trashRestoreSource = Join-Path -Path $rightRoot -ChildPath 'trash_restore_source.txt'
        $trashRestoreTarget = Join-Path -Path $rightRoot -ChildPath 'trash_restore_target.txt'
        Set-Content -LiteralPath $trashRestoreSource -Value 'trash restore new' -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath $trashRestoreTarget -Value 'trash restore old' -Encoding UTF8 -ErrorAction Stop
        $trashMetadataPath = Join-Path -Path $rightRoot -ChildPath 'trash_restore_meta.json'
        Set-Content -LiteralPath $trashMetadataPath -Value '{}' -Encoding UTF8 -ErrorAction Stop
        $overwritePolicy = 'OverwriteAll'
        $trashRestoreResult = Move-PathSafe -Source $trashRestoreSource -Destination $trashRestoreTarget -OverwritePolicy ([ref]$overwritePolicy) -AssumeYes $true -SimulateFailureAfterBackup
        $trashRestoreText = Get-Content -LiteralPath $trashRestoreTarget -Raw -ErrorAction Stop
        if (-not (Test-SelfCondition -Name 'failed trash restore preserves trash item' -Condition ($trashRestoreResult -eq 'Error' -and $trashRestoreText -like '*trash restore old*' -and (Test-Path -LiteralPath $trashRestoreSource) -and (Test-Path -LiteralPath $trashMetadataPath)) -Results $results)) { $failed++ }

        $oldConfigPath = $script:EffectiveConfigPath
        $script:EffectiveConfigPath = Join-Path -Path $root -ChildPath 'config.json'
        [void](Save-AppConfig)
        $loadedConfig = Load-AppConfig
        $script:EffectiveConfigPath = $oldConfigPath
        if (-not (Test-SelfCondition -Name 'config save load' -Condition ($null -ne $loadedConfig -and $loadedConfig.ContainsKey('UserMenu')) -Results $results)) { $failed++ }

        Write-AppLog -Message 'Self-test log write check'
        if (-not (Test-SelfCondition -Name 'log writing' -Condition (Test-Path -LiteralPath $script:EffectiveLogPath) -Results $results)) { $failed++ }
    }
    catch {
        [void]$results.Add(('FAIL unexpected self-test error: {0}' -f $_.Exception.Message))
        Write-AppLog -Level 'ERROR' -Message ('Self-test failed unexpectedly: {0}' -f $_.Exception.ToString())
        $failed++
    }
    finally {
        $script:LocalDataPath = $oldLocalDataPath
        $script:NonInteractiveMode = $oldNonInteractiveMode
        try {
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            }
        }
        catch {
            [void]$results.Add(('WARN cleanup failed: {0}' -f $_.Exception.Message))
        }
    }

    foreach ($line in $results) {
        Write-Output $line
    }
    if ($failed -eq 0) {
        Write-Output 'SELFTEST PASS'
        exit 0
    }
    Write-Output ('SELFTEST FAIL: {0} failed checks' -f $failed)
    exit 1
}

$script:EffectiveLogPath = $LogPath
$script:EffectiveConfigPath = $ConfigPath
Initialize-ApplicationPaths
$script:Config = Load-AppConfig
Initialize-ConfigRuntime

if ($Help.IsPresent) {
    Show-StartupHelp
    exit 0
}

if ($MouseDiagnostics.IsPresent) {
    Start-MouseDiagnosticsMode
    exit 0
}

if ($InputParserSelfTest.IsPresent) {
    Run-InputParserSelfTest
}

Initialize-State

if ($RunSelfTest.IsPresent) {
    Run-SelfTest
}

Start-InteractiveApp
