Function Complete-PSWorkItem {
    [cmdletbinding(SupportsShouldProcess)]
    [Alias('cwi')]
    [OutputType("None","PSWorkItemArchive")]
    Param(
        [Parameter(
            Position = 0,
            Mandatory,
            HelpMessage = "The work item ID.",
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNullOrEmpty()]
        [int]$ID,

        [Parameter(HelpMessage = "The path to the PSWorkItem SQLite database file. It should end in .db")]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern("\.db$")]
        [ValidateScript({
            if (Test-Path $_) {
                Return $True
            }
            else {
                Throw "Failed to validate $_"
                Return $False
            }
        })]
        [String]$Path = $PSWorkItemPath,

        [Parameter(HelpMessage = "Specify the completion date. The default is now.")]
        [ValidateNotNullOrEmpty()]
        [DateTime]$CompletionDate = (Get-Date),

        [Switch]$PassThru
    )
    Begin {
        Write-Verbose "[$((Get-Date).TimeOfDay) BEGIN  ] $($MyInvocation.MyCommand): Starting"
        Write-Verbose "[$((Get-Date).TimeOfDay) BEGIN  ] $($MyInvocation.MyCommand): PSBoundParameters"
        $PSBoundParameters | Out-String | Write-Verbose
        Write-Verbose "[$((Get-Date).TimeOfDay) BEGIN  ] $($MyInvocation.MyCommand): Opening a connection to $Path"
        Try {
            $conn = Open-MySQLiteDB -Path $Path -ErrorAction Stop
            $conn | Out-String | Write-Debug
        }
        Catch {
            Throw "$($MyInvocation.MyCommand): Failed to open the database $Path"
        }

        #parameters to splat to Invoke-MySQLiteQuery
        $splat = @{
            Connection  = $conn
            KeepAlive   = $true
            Query       = ""
            ErrorAction = "Stop"
        }
    } #begin

    Process {
        Write-Verbose "[$((Get-Date).TimeOfDay) PROCESS] $($MyInvocation.MyCommand): Completing task id $ID "
        #test if archive table has been updated to include the OriginalTaskID column
        $test = Invoke-MySQLiteQuery -Path $path -query "pragma table_info('archive')" | Where-Object name -eq 'id'
        if (-Not $test) {
            Write-Warning "Cannot verify the archive table column ID. Please run Update-PSWorkItemDatabase to update the table then try completing the command again. It is recommended that you backup your database before updating the table."
            Return
        }
        #validate the task id
        $splat.query = "SELECT * FROM tasks WHERE ID = '$ID'"
        Write-Debug $splat.query
        Try {
            $task = Invoke-MySQLiteQuery @splat
        }
        Catch {
            Write-Warning "Failed to execute query $($splat.query)"
            Close-MySQLiteDB $conn
            Throw $_
        }
        if ($task.ID -eq $ID) {
            #update the task to mark it complete
            $splat.query = "UPDATE tasks set taskmodified='{0}', completed='1',progress='100' WHERE ID= '{1}'" -f $CompletionDate,$ID
            if ($PSCmdlet.ShouldProcess($splat.query, "Complete-PSWorkItem")) {
                Try {
                    Invoke-MySQLiteQuery @splat
                }
                Catch {
                    Write-Warning "Failed to execute query $($splat.query)"
                    Close-MySQLiteDB $conn
                    Throw $_
                }
                #copy the task to the archive table
                $splat.query = "INSERT into archive SELECT * from tasks WHERE ID= '$ID'"
                # "INSERT into archive SELECT *,ROWID AS originalid from tasks WHERE RowID= '$ID'"
                Write-Verbose "[$((Get-Date).TimeOfDay) PROCESS] $($MyInvocation.MyCommand): Moving item to Archive."
                Write-Debug $splat.query
                Try {
                    Invoke-MySQLiteQuery @splat
                }
                Catch {
                    Write-Warning "Failed to execute query $($splat.query)"
                    Close-MySQLiteDB $conn
                    Throw $_
                }

                #Validate the copy using the task GUID
                $splat.query = "SELECT * from archive WHERE taskid='$($task.taskid)'"
                Write-Verbose "[$((Get-Date).TimeOfDay) PROCESS] $($MyInvocation.MyCommand): Validating the move"
                Write-Debug $splat.query
                Try {
                    $archived = Invoke-MySQLiteQuery @splat
                }
                Catch {
                    Write-Warning "Failed to execute query $($splat.query)"
                    Close-MySQLiteDB $conn
                    Throw $_
                }
                if ($archived.taskid -eq $task.taskId) {
                    #remove the task from the tasks table
                    $splat.query = "DELETE from tasks WHERE taskid = '$($task.taskid)'"
                    Write-Verbose "[$((Get-Date).TimeOfDay) PROCESS] $($MyInvocation.MyCommand): Removing the original task"
                    Write-Debug $splat.query
                    Try {
                        Invoke-MySQLiteQuery @splat
                    }
                    Catch {
                        Write-Warning "Failed to execute query $($splat.query)"
                        Close-MySQLiteDB $conn
                        Throw $_
                    }
                }
                else {
                    Write-Warning "Could not verify that task $ID [$($task.taskid)] was copied to the archive table."
                }
                if ($PassThru) {
                    $splat.Query = "SELECT * from archive WHERE taskid='$($task.taskid)'"
                    Try {
                        $pass = Invoke-MySQLiteQuery @splat
                        #March 10, 2023 PSWorkItemArchive is now a defined class
                        _newWorkItemArchive $pass -path $Path
                    }
                    Catch {
                        Write-Warning "Failed to execute query $($splat.query)"
                        Close-MySQLiteDB $conn
                        Throw $_
                    }
                }
            } #WhatIf
        } #if ID verified
        else {
            Write-Warning "Failed to find task with id $ID"
        }
    } #process

    End {
        if ($conn.state -eq 'Open') {
            Write-Verbose "[$((Get-Date).TimeOfDay) END    ] $($MyInvocation.MyCommand): Closing database connection."
            Close-MySQLiteDB -Connection $conn
        }
        Write-Verbose "[$((Get-Date).TimeOfDay) END    ] $($MyInvocation.MyCommand): Ending "
    } #end

}
