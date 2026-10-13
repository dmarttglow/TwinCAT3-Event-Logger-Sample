<#
.SYNOPSIS
    Adds the EventFramework library to a TwinCAT project.

.DESCRIPTION
    1. Installs the .library into the system library repository (RepTool.exe).
    2. Copies the TMC event classes (e.g. GenericEvents) into the type system of the .tsproj.
    3. Adds the library as a placeholder reference to the PLC project (.plcproj).
    4. Adds the event text list GVL_EventTexts to the PLC project, from templates\GVL_EventTexts.TcGVL.
       An existing GVL_EventTexts is never overwritten.

    The project files are edited as text, so everything else in them stays byte-for-byte the same.
    Every step is idempotent: running the script again only changes what is missing or outdated.
    Close the solution in TwinCAT XAE first, or reload it when XAE asks.

.PARAMETER Project
    Target solution (.sln), system project (.tsproj) or a folder containing exactly one .tsproj.

.PARAMETER PlcProject
    Name of the PLC project to reference the library from. Only needed when the system project
    contains more than one PLC project.

.PARAMETER Source
    Folder holding the files to add. Searched with all subfolders for:
      *.library              highest version wins, then the newest file
      *.tmc                  with event classes; one named like the library wins, then the newest file
      GVL_EventTexts.TcGVL   one in a 'templates' folder wins, then the newest file
    Project caches (_Libraries, _Boot, _CompileInfo) are skipped.
    Without -Source, the script's folder is searched first, then its parent folder.

.PARAMETER LibraryPath
    The .library to install. Overrides the search in -Source.

.PARAMETER TmcPath
    TMC file holding the event classes. Overrides the search in -Source.

.PARAMETER TmcMode
    Inline (default): copies the event classes into the type system stored in the .tsproj.
        The project is self-contained, nothing else to commit.
    AdditionalFile: copies the TMC next to the .tsproj (TypeSystem\<name>.tmc) and registers it under
        System > Type System > Additional TMC files. Commit the copied .tmc, the usual TwinCAT
        .gitignore excludes *.tmc.

.PARAMETER Version
    Library version to resolve to. '*' (default) always uses the newest installed version.

.PARAMETER GvlTemplate
    Template for the event text list. Overrides the search in -Source.

.PARAMETER GvlFolder
    Folder of the PLC project the GVL is added to. Defaults to GVLs.

.PARAMETER SkipGvl
    Don't add the event text list GVL.

.PARAMETER SkipInstall
    Don't install the library, only edit the project files.

.EXAMPLE
    .\Add-EventFramework.ps1 -Project 'D:\Projects\Machine\Machine.sln'

.EXAMPLE
    .\Add-EventFramework.ps1 -Project 'D:\Projects\Machine\Machine.sln' -Source 'D:\Releases\EventFramework'

.EXAMPLE
    .\Add-EventFramework.ps1 -Project 'D:\Projects\Machine' -PlcProject MainPlc -Version 1.0.0.1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Project,

    [Parameter(Position = 1)]
    [string]$Source,

    [string]$PlcProject,

    [string]$LibraryPath,

    [string]$TmcPath,

    [ValidateSet('Inline', 'AdditionalFile')]
    [string]$TmcMode = 'Inline',

    [string]$Version = '*',

    [string]$GvlTemplate,

    [string]$GvlFolder = 'GVLs',

    [switch]$SkipGvl,

    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Read-TextFile([string]$Path) {
    # Keeps the exact content (line endings, BOM) so the file can be written back unchanged.
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    [pscustomobject]@{ Path = $Path; Text = $text; HasBom = $hasBom; NewLine = $newLine }
}

function Write-TextFile($File, [string]$Text, [string]$Action) {
    if ($Text -ceq $File.Text) { return $false }
    if ($PSCmdlet.ShouldProcess($File.Path, $Action)) {
        [IO.File]::WriteAllText($File.Path, $Text, [Text.UTF8Encoding]::new($File.HasBom))
    }
    return $true
}

function Get-LibraryInfo([string]$Path) {
    # A .library is a zip archive; projectinformations.auxiliary holds title, company, version, namespace.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries | Where-Object Name -eq 'projectinformations.auxiliary' | Select-Object -First 1
        if (-not $entry) { throw "No project information found in '$Path'. Is it a TwinCAT .library?" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }

    # XPath, not $xml.ProjectInformations.properties: PowerShell would also match <Properties>.
    $p = $xml.SelectSingleNode('/ProjectInformations/properties')
    function Get-Value([string]$Name) { $node = $p.SelectSingleNode($Name); if ($node) { $node.InnerText } }
    $title = Get-Value 'Title'
    $placeholder = Get-Value 'Placeholder'
    $namespace = Get-Value 'DefaultNamespace'
    [pscustomobject]@{
        Title       = $title
        Company     = Get-Value 'Company'
        Version     = Get-Value 'Version'
        Placeholder = if ($placeholder) { $placeholder } else { $title }
        Namespace   = if ($namespace) { $namespace } else { $title }
    }
}

function Find-SourceFiles([string[]]$Roots, [string]$Filter, [scriptblock]$Where = { $true }) {
    # Returns the matches of the first root that has any. Project caches hold stale copies, skip them.
    foreach ($root in $Roots) {
        $found = @(Get-ChildItem $root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(_Libraries|_Boot|_CompileInfo)\\' } |
            Where-Object -FilterScript $Where)
        if ($found.Count -gt 0) { return $found }
    }
    return @()
}

function Find-LibraryFile([string[]]$Roots) {
    $found = @(Find-SourceFiles $Roots '*.library')
    if ($found.Count -eq 0) { throw "No .library found in: $($Roots -join ', '). Pass -Source or -LibraryPath." }

    $candidates = @(foreach ($f in $found) {
        $info = Get-LibraryInfo $f.FullName
        [pscustomobject]@{ File = $f; Title = $info.Title; Version = [version]$info.Version }
    })
    # Another vendor's library next to ours doesn't count, as long as ours is there.
    $titles = @($candidates.Title | Select-Object -Unique)
    if ($titles.Count -gt 1) {
        $candidates = @($candidates | Where-Object Title -eq 'EventFramework')
        if ($candidates.Count -eq 0) {
            throw "Several different libraries found ($($titles -join ', ')). Pass the one to use with -LibraryPath."
        }
    }
    ($candidates | Sort-Object @{ Expression = 'Version'; Descending = $true }, @{ Expression = { $_.File.LastWriteTime }; Descending = $true } |
        Select-Object -First 1).File.FullName
}

function Find-TmcFile([string[]]$Roots, [string]$LibraryTitle) {
    $found = @(Find-SourceFiles $Roots '*.tmc' { Select-String -Path $_.FullName -Pattern '<EventId>' -SimpleMatch -Quiet })
    if ($found.Count -eq 0) { throw "No .tmc with event classes found in: $($Roots -join ', '). Pass -Source or -TmcPath." }
    ($found | Sort-Object @{ Expression = { $_.BaseName -eq $LibraryTitle }; Descending = $true }, @{ Expression = 'LastWriteTime'; Descending = $true } |
        Select-Object -First 1).FullName
}

function Find-GvlTemplate([string[]]$Roots) {
    $found = @(Find-SourceFiles $Roots 'GVL_EventTexts.TcGVL')
    if ($found.Count -eq 0) { throw "No GVL_EventTexts.TcGVL found in: $($Roots -join ', '). Pass -Source or -GvlTemplate, or use -SkipGvl." }
    ($found | Sort-Object @{ Expression = { $_.FullName -match '\\templates\\' }; Descending = $true }, @{ Expression = 'LastWriteTime'; Descending = $true } |
        Select-Object -First 1).FullName
}

function Find-RepTool([string]$TcVersion) {
    # Returns RepTool.exe and its matching profile, preferring the build the project was saved with.
    $roots = @($env:TWINCAT3DIR, 'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1', 'C:\TwinCAT\3.1') |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'Components\Plc')) } |
        ForEach-Object { (Resolve-Path (Join-Path $_ 'Components\Plc')).Path } |
        Select-Object -Unique

    $candidates = foreach ($root in $roots) {
        # 4026+: Components\Plc\Build_<x>\Common  /  4024: Components\Plc\Common
        $dirs = @(Get-ChildItem $root -Directory -Filter 'Build_*' -ErrorAction SilentlyContinue) + @(Get-Item $root)
        foreach ($dir in $dirs) {
            $exe = Join-Path $dir.FullName 'Common\RepTool.exe'
            if (-not (Test-Path $exe)) { continue }
            $profileFile = Get-ChildItem (Join-Path $dir.FullName 'Profiles') -Filter 'TwinCAT PLC Control_Build_*.profile*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if (-not $profileFile) { continue }
            $profileName = $profileFile.Name -replace '\.profile(\.xml)?$', ''
            [pscustomobject]@{
                Exe     = $exe
                Profile = $profileName
                Build   = [version]($profileName -replace '^.*_Build_', '')
            }
        }
    }
    if (-not $candidates) { throw 'RepTool.exe not found. Is TwinCAT XAE installed?' }

    $wanted = if ($TcVersion -match '^\d+\.\d+\.(\d+)\.(\d+)$') { [version]"$($Matches[1]).$($Matches[2])" }
    $match = $candidates | Where-Object { $_.Build -eq $wanted } | Select-Object -First 1
    if ($match) { return $match }
    return $candidates | Sort-Object Build -Descending | Select-Object -First 1
}

function Invoke-RepTool($Tool, [string]$Arguments) {
    # ProcessStartInfo keeps the quoting RepTool needs (--profile="name with spaces").
    $psi = [Diagnostics.ProcessStartInfo]::new($Tool.Exe)
    $psi.Arguments = "--profile=`"$($Tool.Profile)`" $Arguments"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "RepTool failed (exit code $($process.ExitCode)):`n$($stdout.Result)`n$stderr"
    }
}

function Find-SystemProject([string]$Path) {
    $item = Get-Item (Resolve-Path $Path)
    if ($item.PSIsContainer) {
        $found = @(Get-ChildItem $item.FullName -Recurse -Filter '*.tsproj' |
            Where-Object { $_.FullName -notmatch '\\_Boot\\' })
    }
    elseif ($item.Extension -eq '.tsproj') {
        $found = @($item)
    }
    elseif ($item.Extension -eq '.sln') {
        $found = @(Select-String -Path $item.FullName -Pattern '"([^"]+\.tsproj)"' -AllMatches |
            ForEach-Object { $_.Matches } |
            ForEach-Object { Get-Item (Join-Path $item.DirectoryName $_.Groups[1].Value) })
    }
    else {
        throw "'$Path' is not a .sln, .tsproj or folder."
    }

    if ($found.Count -eq 0) { throw "No .tsproj found in '$Path'." }
    if ($found.Count -gt 1) {
        throw "Found more than one .tsproj, pass one of them with -Project:`n  $($found.FullName -join "`n  ")"
    }
    return $found[0].FullName
}

function Get-PlcProjects([string]$TsprojPath, [xml]$Tsproj) {
    $dir = Split-Path $TsprojPath
    foreach ($node in $Tsproj.SelectNodes('/TcSmProject/Project/Plc/Project')) {
        $prjFile = $node.GetAttribute('PrjFilePath')
        $name = $node.GetAttribute('Name')
        if (-not $prjFile -and $node.GetAttribute('File')) {
            # "Use independent project file": the details are in _Config\PLC\<name>.xti
            [xml]$xti = Get-Content -Raw (Join-Path $dir "_Config\PLC\$($node.GetAttribute('File'))")
            $inner = $xti.SelectSingleNode('/TcSmItem/Project')
            $prjFile = $inner.GetAttribute('PrjFilePath')
            $name = $inner.GetAttribute('Name')
        }
        if (-not $prjFile) { continue }
        [pscustomobject]@{ Name = $name; Path = (Join-Path $dir $prjFile) }
    }
}

# ---------------------------------------------------------------------------------------------
# Step 2: event classes -> .tsproj type system
# ---------------------------------------------------------------------------------------------

function Add-EventClasses([string]$TsprojPath, [string]$TmcPath) {
    $tmcText = (Read-TextFile $TmcPath).Text
    [xml]$tmc = $tmcText
    $classes = @($tmc.SelectNodes('/TcModuleClass/DataTypes/DataType[EventId]'))
    if ($classes.Count -eq 0) {
        Write-Warning "No event classes in '$TmcPath', type system left unchanged."
        return
    }

    $file = Read-TextFile $TsprojPath
    $nl = $file.NewLine
    $text = $file.Text
    [xml]$tsproj = $text

    foreach ($class in $classes) {
        $nameNode = $class.SelectSingleNode('Name')
        $guid = $nameNode.GetAttribute('GUID')
        $className = $nameNode.InnerText

        # The raw block from the TMC keeps its formatting. DataTypes sit at the same depth in both files.
        $pattern = '(?s)\t\t<DataType>\s*<Name GUID="' + [regex]::Escape($guid) + '".*?</DataType>'
        $block = [regex]::Match($tmcText, $pattern).Value
        if (-not $block) { throw "Could not extract event class '$className' from '$TmcPath'." }
        $block = $block -replace "\r?\n", $nl
        # XAE marks event classes in the type system as persistent so they are kept when unused.
        $block = $block -replace '(<Name GUID="[^"]+")(?![^>]*PersistentType)', '$1 PersistentType="true"'

        $sameName = $tsproj.SelectSingleNode("/TcSmProject/DataTypes/DataType/Name[.='$className']")
        if ($sameName -and $sameName.GetAttribute('GUID') -ne $guid) {
            throw "The type system already has a different '$className' (GUID $($sameName.GetAttribute('GUID'))). Remove or rename it first."
        }

        $existing = [regex]::Match($text, $pattern)
        if ($existing.Success) {
            if ($existing.Value -ceq $block) {
                Write-Host "  Event class '$className' is up to date."
                continue
            }
            $text = $text.Remove($existing.Index, $existing.Length).Insert($existing.Index, $block)
            Write-Host "  Event class '$className' updated."
        }
        elseif ($text -match "(?m)^\t</DataTypes>") {
            $index = [regex]::Match($text, "(?m)^\t</DataTypes>").Index
            $text = $text.Insert($index, $block + $nl)
            Write-Host "  Event class '$className' added."
        }
        else {
            # No type system entries yet: create <DataTypes> in front of the root <Project>.
            $index = [regex]::Match($text, "(?m)^\t<Project ").Index
            if ($index -le 0) { throw "Unexpected .tsproj layout in '$TsprojPath'." }
            $text = $text.Insert($index, "`t<DataTypes>$nl$block$nl`t</DataTypes>$nl")
            Write-Host "  Event class '$className' added."
        }
    }

    [void](Write-TextFile $file $text 'Add event classes to the type system')
}

function Add-AdditionalTmcFile([string]$TsprojPath, [string]$TmcPath, [string]$Name) {
    $relative = "TypeSystem\$Name.tmc"
    $target = Join-Path (Split-Path $TsprojPath) $relative

    $sameFile = (Test-Path $target) -and
        (Get-FileHash $target).Hash -eq (Get-FileHash $TmcPath).Hash
    if ($sameFile) {
        Write-Host "  $relative is up to date."
    }
    elseif ($PSCmdlet.ShouldProcess($target, 'Copy TMC')) {
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $TmcPath $target -Force
        Write-Host "  Copied TMC to $relative."
    }

    $file = Read-TextFile $TsprojPath
    $nl = $file.NewLine
    $text = $file.Text
    $line = "`t`t`t`t<AdditionalTmcFile Name=`"$Name`" File=`"$relative`"/>"

    $existing = [regex]::Match($text, '(?m)^\t\t\t\t<AdditionalTmcFile Name="' + [regex]::Escape($Name) + '"[^>]*/>')
    if ($existing.Success) {
        if ($existing.Value -ceq $line) {
            Write-Host "  Additional TMC file '$Name' is already registered."
            return
        }
        $text = $text.Remove($existing.Index, $existing.Length).Insert($existing.Index, $line)
        Write-Host "  Additional TMC file '$Name' now points to $relative."
    }
    elseif ($text -match "(?m)^\t\t\t</TypeSystem>") {
        $index = [regex]::Match($text, "(?m)^\t\t\t</TypeSystem>").Index
        $text = $text.Insert($index, $line + $nl)
        Write-Host "  Additional TMC file '$Name' registered."
    }
    else {
        $index = [regex]::Match($text, "(?m)^\t\t</System>").Index
        if ($index -le 0) { throw "No <System> section found in '$TsprojPath'." }
        $text = $text.Insert($index, "`t`t`t<TypeSystem>$nl$line$nl`t`t`t</TypeSystem>$nl")
        Write-Host "  Additional TMC file '$Name' registered."
    }

    [void](Write-TextFile $file $text 'Register additional TMC file')
}

function Test-DuplicateEventClasses([string]$TsprojPath, [string]$TmcPath, [string]$TmcMode) {
    # The same event class both inline and in an additional TMC file gives duplicate types.
    [xml]$tmc = Get-Content -Raw $TmcPath
    [xml]$tsproj = Get-Content -Raw $TsprojPath
    $hasAdditional = $null -ne $tsproj.SelectSingleNode('/TcSmProject/Project/System/TypeSystem/AdditionalTmcFile')
    foreach ($guid in $tmc.SelectNodes('/TcModuleClass/DataTypes/DataType[EventId]/Name/@GUID').Value) {
        $inline = $tsproj.SelectSingleNode("/TcSmProject/DataTypes/DataType/Name[@GUID='$guid']")
        if ($TmcMode -eq 'AdditionalFile' -and $inline) {
            Write-Warning "Event class '$($inline.InnerText)' is also stored inline in the type system. Delete it there (System > Type System > Event Classes) to avoid a duplicate."
        }
        if ($TmcMode -eq 'Inline' -and $hasAdditional) {
            Write-Warning 'The project also has additional TMC files. If one of them is the EventFramework TMC, remove it (System > Type System > Additional TMC files) to avoid a duplicate.'
            return
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Step 3: library reference -> .plcproj
# ---------------------------------------------------------------------------------------------

function Add-LibraryReference([string]$PlcprojPath, $Library, [string]$Version) {
    $file = Read-TextFile $PlcprojPath
    $nl = $file.NewLine
    $text = $file.Text
    $resolution = "$($Library.Title), $Version ($($Library.Company))"

    $block = "    <PlaceholderReference Include=`"$($Library.Placeholder)`">$nl" +
             "      <DefaultResolution>$resolution</DefaultResolution>$nl" +
             "      <Namespace>$($Library.Namespace)</Namespace>$nl" +
             "    </PlaceholderReference>$nl"

    $refPattern = '(?s)    <PlaceholderReference Include="([^"]+)">.*?</PlaceholderReference>\r?\n'
    $refs = [regex]::Matches($text, $refPattern)
    $existing = $refs | Where-Object { $_.Groups[1].Value -eq $Library.Placeholder } | Select-Object -First 1

    if ($existing) {
        # Keep any extra settings of the existing reference, only fix its resolution and namespace.
        $updated = $existing.Value `
            -replace '<DefaultResolution>[^<]*</DefaultResolution>', "<DefaultResolution>$resolution</DefaultResolution>" `
            -replace '<Namespace>[^<]*</Namespace>', "<Namespace>$($Library.Namespace)</Namespace>"
        if ($updated -ceq $existing.Value) {
            Write-Host "  Reference '$resolution' is up to date."
            return
        }
        $text = $text.Remove($existing.Index, $existing.Length).Insert($existing.Index, $updated)
        Write-Host "  Reference updated to '$resolution'."
    }
    elseif ($refs.Count -gt 0) {
        # XAE keeps the references sorted by name.
        $next = $refs | Where-Object { [string]::Compare($_.Groups[1].Value, $Library.Placeholder, $true) -gt 0 } | Select-Object -First 1
        $index = if ($next) { $next.Index } else { $refs[$refs.Count - 1].Index + $refs[$refs.Count - 1].Length }
        $text = $text.Insert($index, $block)
        Write-Host "  Reference '$resolution' added."
    }
    else {
        $index = [regex]::Match($text, '(?m)^  <ProjectExtensions').Index
        if ($index -le 0) { $index = $text.LastIndexOf('</Project>') }
        $text = $text.Insert($index, "  <ItemGroup>$nl$block  </ItemGroup>$nl")
        Write-Host "  Reference '$resolution' added."
    }

    [void](Write-TextFile $file $text "Add library reference '$resolution'")
}

# ---------------------------------------------------------------------------------------------
# Step 4: event text list GVL -> PLC project
# ---------------------------------------------------------------------------------------------

function Add-SortedItem([string]$Text, [string]$NewLine, [string]$Element, [string]$Include, [string]$Block) {
    # Inserts an <ItemGroup> entry in XAE's order (ordinal by Include), or a new <ItemGroup> if there is none.
    $pattern = '(?s)    <' + $Element + ' Include="([^"]+)"(?: />|>.*?</' + $Element + '>)\r?\n'
    $items = [regex]::Matches($Text, $pattern)
    if ($items.Count -gt 0) {
        $next = $items | Where-Object { [string]::CompareOrdinal($_.Groups[1].Value, $Include) -gt 0 } | Select-Object -First 1
        $index = if ($next) { $next.Index } else { $items[$items.Count - 1].Index + $items[$items.Count - 1].Length }
        return $Text.Insert($index, $Block)
    }
    $index = [regex]::Match($Text, '(?m)^  <ProjectExtensions').Index
    if ($index -le 0) { $index = $Text.LastIndexOf('</Project>') }
    return $Text.Insert($index, "  <ItemGroup>$NewLine$Block  </ItemGroup>$NewLine")
}

function Add-PlcObject([string]$PlcprojPath, [string]$TemplatePath, [string]$Folder) {
    $template = Read-TextFile (Resolve-Path $TemplatePath).Path
    [xml]$xml = $template.Text
    $objectNode = $xml.DocumentElement.SelectSingleNode('*[@Name]')
    $fileName = $objectNode.GetAttribute('Name') + [IO.Path]::GetExtension($TemplatePath)
    $include = if ($Folder) { "$($Folder.Trim('\'))\$fileName" } else { $fileName }

    $file = Read-TextFile $PlcprojPath
    $nl = $file.NewLine
    $text = $file.Text

    # Never touch an existing object: it holds this project's own texts.
    $existing = [regex]::Match($text, '<Compile Include="((?:[^"]*\\)?' + [regex]::Escape($fileName) + ')"')
    if ($existing.Success) {
        Write-Host "  $($existing.Groups[1].Value) already in the project, left unchanged."
        return
    }

    $target = Join-Path (Split-Path $PlcprojPath) $include
    if (Test-Path $target) {
        Write-Host "  $include exists on disk but not in the project: registering it, content left unchanged."
    }
    elseif ($PSCmdlet.ShouldProcess($target, 'Create from template')) {
        # New object id, and the BOM + CRLF that XAE writes.
        $content = $template.Text -replace 'Id="\{[0-9a-fA-F-]+\}"', "Id=`"{$([guid]::NewGuid())}`""
        $content = $content -replace '\r?\n', "`r`n"
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($true))
        Write-Host "  Created $include."
    }

    $block = "    <Compile Include=`"$include`">$nl      <SubType>Code</SubType>$nl    </Compile>$nl"
    $text = Add-SortedItem $text $nl 'Compile' $include $block

    # Every folder level needs its own <Folder> entry.
    $parts = @(($include -split '\\') | Select-Object -SkipLast 1)
    for ($i = 1; $i -le $parts.Count; $i++) {
        $folderPath = $parts[0..($i - 1)] -join '\'
        if ($text -notmatch '<Folder Include="' + [regex]::Escape($folderPath) + '" />') {
            $text = Add-SortedItem $text $nl 'Folder' $folderPath "    <Folder Include=`"$folderPath`" />$nl"
        }
    }

    if (Write-TextFile $file $text "Add $include") {
        Write-Host "  Added $include to the PLC project."
    }
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

# Search roots set here: Windows PowerShell 5.1 has no $PSScriptRoot in parameter defaults.
$roots = if ($Source) {
    if (-not (Test-Path $Source -PathType Container)) { throw "Source folder '$Source' not found." }
    @((Resolve-Path $Source).Path)
}
else {
    @($PSScriptRoot, (Split-Path $PSScriptRoot))
}

if ($LibraryPath) { $LibraryPath = (Resolve-Path $LibraryPath).Path }
else { $LibraryPath = Find-LibraryFile $roots }
$library = Get-LibraryInfo $LibraryPath

if ($TmcPath) { $TmcPath = (Resolve-Path $TmcPath).Path }
else { $TmcPath = Find-TmcFile $roots $library.Title }

if (-not $SkipGvl) {
    if ($GvlTemplate) { $GvlTemplate = (Resolve-Path $GvlTemplate).Path }
    else { $GvlTemplate = Find-GvlTemplate $roots }
}

$tsprojPath = Find-SystemProject $Project
[xml]$tsproj = Get-Content -Raw $tsprojPath
$tcVersion = $tsproj.TcSmProject.TcVersion

$plcProjects = @(Get-PlcProjects $tsprojPath $tsproj |
    Where-Object { -not (Select-String -Path $_.Path -Pattern "<Title>$([regex]::Escape($library.Title))</Title>" -Quiet) })
if ($PlcProject) {
    $plcProjects = @($plcProjects | Where-Object Name -eq $PlcProject)
    if ($plcProjects.Count -eq 0) { throw "PLC project '$PlcProject' not found in '$tsprojPath'." }
}
elseif ($plcProjects.Count -gt 1) {
    throw "The system project has several PLC projects, pick one with -PlcProject: $($plcProjects.Name -join ', ')"
}
if ($plcProjects.Count -eq 0) { throw "No PLC project found in '$tsprojPath'." }
$plc = $plcProjects[0]

Write-Host "Library      : $($library.Title) $($library.Version) ($($library.Company))"
Write-Host "  from       : $LibraryPath"
Write-Host "TMC          : $TmcPath"
if (-not $SkipGvl) { Write-Host "GVL template : $GvlTemplate" }
Write-Host "System       : $tsprojPath"
Write-Host "PLC project  : $($plc.Name)"
Write-Host ''

Write-Host '1/4 Installing library'
if ($SkipInstall) {
    Write-Host '  Skipped.'
}
else {
    $tool = Find-RepTool $tcVersion
    if ($PSCmdlet.ShouldProcess("$($library.Title) $($library.Version)", "Install into the system repository with $($tool.Profile)")) {
        Invoke-RepTool $tool "--installLib `"$LibraryPath`""
        Write-Host "  Installed with $($tool.Profile)."
    }
}

Write-Host "2/4 Adding event classes to the type system ($TmcMode)"
if ($TmcMode -eq 'Inline') {
    Add-EventClasses $tsprojPath $TmcPath
}
else {
    Add-AdditionalTmcFile $tsprojPath $TmcPath $library.Title
}
Test-DuplicateEventClasses $tsprojPath $TmcPath $TmcMode

Write-Host '3/4 Adding library reference'
Add-LibraryReference $plc.Path $library $Version

Write-Host '4/4 Adding event text list'
if ($SkipGvl) {
    Write-Host '  Skipped.'
}
else {
    Add-PlcObject $plc.Path $GvlTemplate $GvlFolder
}

Write-Host ''
Write-Host 'Done. If the solution is open in TwinCAT XAE, reload it when asked, then build.'
