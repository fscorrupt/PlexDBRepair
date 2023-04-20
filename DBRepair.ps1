#########################################################################
# Plex Media Server database check and repair utility script.           #
# Maintainer: fscorrupt                                                   #
# Version:    v0.0.1                                                    #
# Date:       20-Apr-2023                                               #
#########################################################################

# Version for display purposes
$Version = "v0.0.1"

##################
# Variable Start #
##################

# Create Timestamp
$TimeStamp = Get-Date -Format 'yyyy-MM-dd_hh.mm.ss'

# Query PMS default Locations
$InstallLocation = ((Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall, HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue| Where-Object {$_.DisplayName -match 'Plex Media Server'})).InstallLocation
$PlexData = "$env:LOCALAPPDATA\Plex Media Server\Plug-in Support\Databases"
$CPPL = "com.plexapp.plugins.library"
$PlexDBPath = "$PlexData\$CPPL.db"
$PLEX_SQLITE = $InstallLocation +"Plex SQLite.exe"
$DBtmp = "$PlexData\dbtmp"
$TmpFile = "$DBtmp\results.tmp"

# Flag when temp files are to be retained
$Retain=0

# Have the databases passed integrity checks
$CheckedDB=0

# By default,  we cannot start/stop PMS
$HaveStartStop=0
$StartStopUser=0
$StartCommand=""
$StopCommand=""

# Keep track of how many times the user's hit enter with no command (implied EOF)
$NullCommands=0

# Initialize global runtime variables
$CheckedDB=0
$Damaged=0
$Fail=0
$HaveStartStop=0
$HostType="Windows"
$LOG_TOOL = "Powershell"
$ShowMenu=1
################
# Variable End #
################

function WriteOutput($output) {
    $log = $(Get-Date -Format 'yyyy-MM-dd | hh:mm:ss')+' --  '+$output
    Write-Host $log
    Add-Content -Path "$PlexData\PlexDBRepair.log" -Value $log
}
function CheckDB($path) {
    # Confirm the DB exists
    if (-not (Test-Path $path)) {
        WriteOutput "ERROR: $path does not exist."
        return 1
    }
    
    # Now check database for corruption
    $Result = & $PLEX_SQLITE $path "PRAGMA integrity_check(1)"
    if ($Result -eq "ok") {
        return 0
    }
    else {
        $SQLerror = $Result -replace ".*code "
        return 1
    }
}
function CheckDatabases {
    param (
        [string]$CallingFunction,
        [string]$Force = ""
    )
    # Check each of the databases. If all pass, set the 'CheckedDB' flag
    # Only force recheck if flag given

    # Check if not checked or forced
    $NeedCheck = 0
    if ($global:CheckedDB -eq 0) { $NeedCheck = 1 }
    if ($global:CheckedDB -eq 1 -and $Force -eq "force") { $NeedCheck = 1 }

    # Do we need to check
    if ($NeedCheck -eq 1) {

        # Clear Damaged flag
        $global:Damaged = 0
        $global:CheckedDB = 0

        # Info
        WriteOutput "Checking the PMS databases"

        # Check main DB
        if (CheckDB "$PlexData\$CPPL.db") {
            WriteOutput "Check complete. PMS main database is OK."
            WriteOutput "$CallingFunction - Check $CPPL.db - PASS"
        }
        else {
            WriteOutput "Check complete. PMS main database is damaged."
            WriteOutput "$CallingFunction - Check $CPPL.db - FAIL ($SQLerror)"
            $global:Damaged = 1
        }

        # Check blobs DB
        if (CheckDB "$PlexData\$CPPL.blobs.db") {
            WriteOutput "Check complete. PMS blobs database is OK."
            WriteOutput "$CallingFunction - Check $CPPL.blobs.db - PASS"
        }
        else {
            WriteOutput "Check complete. PMS blobs database is damaged."
            WriteOutput "$CallingFunction - Check $CPPL.blobs.db - FAIL ($SQLerror)"
            $global:Damaged = 1
        }

        # Yes, we've now checked it
        $global:CheckedDB = 1
    }

    if ($global:Damaged -eq 0) { $global:CheckedDB = 1 }

    # return status
    return $global:Damaged
}
function GetDates {
    $Dates = ""
    $Tempfile = New-TemporaryFile
    foreach ($i in @(Get-ChildItem -Path . -MaxDepth 1 -Filter "com.plexapp.plugins.library.db-????-??-??" | Sort-Object -Descending)) {
        # echo Date - "${i//[^.]*db-/}"
        $Date = $i.Name -replace ".*.db-"
        # Only add if companion blobs DB exists
        if (Test-Path "$CPPL.blobs.db-$Date") {
            Add-Content -Path $Tempfile.FullName -Value $Date
        }
    }
    # Reload dates in sorted order
    $Dates = Get-Content -Path $Tempfile.FullName | Sort-Object -Descending

    # Remove tempfile
    Remove-Item -Path $Tempfile.FullName

    # Give results
    WriteOutput $Dates
}
function SQLiteOK($ErrorCode) {
    # Global error variable
    $SQLerror = 0

    # Quick exit - known OK
    if ($ErrorCode -eq 0) { return 0 }

    # Put list of acceptable error codes here
    $Codes = @(19, 28)

    # By default assume the given code is an error
    $CodeError = 1

    foreach ($i in $Codes) {
        if ($i -eq $ErrorCode) {
            $CodeError = 0
            $SQLerror = $i
            break
        }
    }
    return $CodeError
}
function FreeSpaceAvailable($Multiplier = 3) {
    $SpaceAvailable = (Get-Volume | Where-Object DriveLetter -eq $PlexData.Split(':')[0]).SizeRemaining

    # Get size of DB and blobs, Minimally needing sum of both
    $LibSize = ( Get-Item -Path "$PlexData\$CPPL.db").Length
    $BlobsSize = (Get-Item -Path "$PlexData\$CPPL.blobs.db").Length
    $SpaceNeeded = ($LibSize + $BlobsSize)

    # Compute need (minimum $Multiplier existing; current, backup, temp and room to write new)
    $SpaceNeeded = [Math]::Round(($SpaceNeeded * $Multiplier))

    # If need < available, all good
    if ($SpaceNeeded -lt $SpaceAvailable) {
        return 0
    }
    Else {
        return 1
    }
}
function DoBackup {
    if (Test-Path $args[1]) {
    Copy-Item $args[1] $args[2] -Force -PassThru
    $Result = $LASTEXITCODE
    if ($Result -ne 0) {
        WriteOutput "Error $Result while backing up '$($args[1])'. Cannot continue."
        WriteOutput "MakeBackup $($args[1]) - FAIL"
            # Remove partially copied file and return
            Remove-Item $args[2] -Force
            return 1
        }
        else {
            WriteOutput "MakeBackup $($args[1]) - PASS"
            return 0
        }
    }
}    
function MakeBackups {
    WriteOutput "Backup current databases with '-BACKUP-$TimeStamp' timestamp."
    $Result = $null
    $dbFiles = @("db", "db-wal", "db-shm", "blobs.db", "blobs.db-wal", "blobs.db-shm")
    foreach ($file in $dbFiles) {
        $Result = DoBackup "$PlexData\$CPPL.$file" "$DBTMP\$CPPL.$file-BACKUP-$TimeStamp"
        return $Result 
    }
}
function ConfirmYesNo {
    $Answer = ""
    while ($Answer -eq "") {
        Write-Host -NoNewline "$($args[0]) (Y/N)? "
        $Input = Read-Host
        # EOF = No
        if ([string]::IsNullOrEmpty($Input)) {
            $Answer = "N"
        }
        elseif ($Input -eq "n" -or $Input -eq "N") {
            $Answer = "N"
        }
        elseif ($Input -eq "y" -or $Input -eq "Y") {
            $Answer = "Y"
        }
        # Unrecognized
        if ($Answer -ne "Y" -and $Answer -ne "N") {
            Write-Host "'$Input' was not a valid reply. Please try again."
            continue
        }
    }
    if ($Answer -eq "Y") {
        # Confirmed Yes
        return 0
    }
    else {
        return 1
    }
}
function RestoreSaved($T) {
    $fileNames = "db", "db-wal", "db-shm", "blobs.db", "blobs.db-wal", "blobs.db-shm"

    foreach ($i in $fileNames) {
        if (Test-Path "$PlexData\$CPPL.$i") { Remove-Item "$PlexData\$CPPL.$i" }
        if (Test-Path "$DBTMP\$CPPL.$i-BACKUP-$T") { Move-Item "$DBTMP\$CPPL.$i-BACKUP-$T" "$PlexData\$CPPL.$i" }
    }
}
function GetSize($filePath) {
    $Size = ((Get-Item $filePath).Length)
    $Size = [math]::Floor($Size / 1048576)
    if ($Size -eq 0) { $Size = 1 }
    WriteOutput $Size
}
function SetLast {
    Param(
        [string]$LastName,
        [string]$LastTimestamp
    )
    return 0
}
function DoIndex {
    # Clear flag
    $Damaged = 0
    $Fail = 0

    # Check databases before Indexing if not previously checked
    if (-not (CheckDatabases "Reindex")) {
        $Damaged = 1
        $CheckedDB = 1
        $Fail = 1
    }

    # If damaged, exit
    if ($Damaged -eq 1) {
        WriteOutput "Databases are damaged. Reindex operation not available.  Please repair or replace first."
        return
    }

    # Databases are OK,  Make a backup
    WriteOutput "Backing up of databases"
    MakeBackups "Reindex"
    $Result = $LastExitCode
    if ($Result -eq 0) {
        WriteOutput "Reindex - MakeBackup - PASS"
    }
    else {
        WriteOutput "Error making backups.  Cannot continue."
        WriteOutput "Reindex - MakeBackup - FAIL ($Result)"
        $Fail = 1
        return
    }

    # Databases are OK,  Start reindexing
    WriteOutput "Reindexing main database"
    & "$PLEX_SQLITE" "$CPPL.db" 'REINDEX;'
    $Result = $LastExitCode
    if (SQLiteOK $Result) {
        WriteOutput "Reindexing main database successful."
        WriteOutput "Reindex - Reindex: $CPPL.db - PASS"
    }
    else {
        WriteOutput "Reindexing main database failed. Error code $Result from Plex SQLite"
        WriteOutput "Reindex - Reindex: $CPPL.db - FAIL ($Result)"
        $Fail = 1
    }

    WriteOutput "Reindexing blobs database"
    & "$PLEX_SQLITE" "$CPPL.blobs.db" 'REINDEX;'
    $Result = $LastExitCode
    if (SQLiteOK $Result) {
        WriteOutput "Reindexing blobs database successful."
        WriteOutput "Reindex - Reindex: $CPPL.blobs.db - PASS"
    }
    else {
        WriteOutput "Reindexing blobs database failed. Error code $Result from Plex SQLite"
        WriteOutput "Reindex - Reindex: $CPPL.blobs.db - FAIL ($Result)"
        $Fail = 1
    }

    WriteOutput "Reindex complete."

    if ($Fail -eq 0) {
        SetLast "Reindex" "$TimeStamp"
        WriteOutput "Reindex - PASS"
    }
    else {
        RestoreSaved "$TimeStamp"
        WriteOutput "Reindex - FAIL"
    }

    return $Fail
}
function DoUndo {
    if ($LastTimestamp -ne "") {
        WriteOutput ""
        WriteOutput "'Undo' restores the databases to the state prior to the last SUCCESSFUL action."
        WriteOutput "If any action fails before it completes, that action is automatically undone for you."
        WriteOutput "Be advised: Undo restores the databases to their state PRIOR TO the last action of 'Vacuum', 'Reindex', or 'Replace'"
        WriteOutput "WARNING: Once Undo completes, there will be nothing more to Undo untl another successful action is completed"
        WriteOutput ""
        if ((ConfirmYesNo "Undo '$LastName' performed at timestamp '$LastTimestamp' ?")) {
            WriteOutput "Undoing $LastName ($LastTimestamp)"
        
            $files = "db", "db-wal", "db-shm", "blobs.db", "blobs.db-wal", "blobs.db-shm"
            foreach ($j in $files) {
                if (Test-Path "$DBTMP\$CPPL.$j-BACKUP-$LastTimestamp") {
                    Move-Item -Force "$DBTMP\$CPPL.$j-BACKUP-$LastTimestamp" "$CPPL.$j)"
                }
            }
        
            WriteOutput "Undo complete."
            WriteOutput "Undo    - Undo ${LastName}, TimeStamp $LastTimestamp"
            SetLast "Undo" ""
        }
    }
    else {
        WriteOutput "Nothing to undo."
        WriteOutput "Undo    - Nothing to Undo."
    }
}
