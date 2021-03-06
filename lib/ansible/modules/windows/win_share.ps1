#!powershell
# This file is part of Ansible

# Copyright 2015, Hans-Joachim Kliemeck <git@kliemeck.de>
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

#Functions
Function UserSearch
{
    Param ([string]$accountName)
    #Check if there's a realm specified

    $searchDomain = $false
    $searchDomainUPN = $false
    if ($accountName.Split("\").count -gt 1)
    {
        if ($accountName.Split("\")[0] -ne $env:COMPUTERNAME)
        {
            $searchDomain = $true
            $accountName = $accountName.split("\")[1]
        }
    }
    Elseif ($accountName.contains("@"))
    {
        $searchDomain = $true
        $searchDomainUPN = $true
    }
    Else
    {
        #Default to local user account
        $accountName = $env:COMPUTERNAME + "\" + $accountName
    }

    if ($searchDomain -eq $false)
    {
        # do not use Win32_UserAccount, because e.g. SYSTEM (BUILTIN\SYSTEM or COMPUUTERNAME\SYSTEM) will not be listed. on Win32_Account groups will be listed too
        $localaccount = get-wmiobject -class "Win32_Account" -namespace "root\CIMV2" -filter "(LocalAccount = True)" | where {$_.Caption -eq $accountName}
        if ($localaccount)
        {
            return $localaccount.SID
        }
    }
    Else
    {
        #Search by samaccountname
        $Searcher = [adsisearcher]""

        If ($searchDomainUPN -eq $false) {
            $Searcher.Filter = "sAMAccountName=$($accountName)"
        }
        Else {
            $Searcher.Filter = "userPrincipalName=$($accountName)"
        }

        $result = $Searcher.FindOne()
        if ($result)
        {
            $user = $result.GetDirectoryEntry()

            # get binary SID from AD account
            $binarySID = $user.ObjectSid.Value

            # convert to string SID
            return (New-Object System.Security.Principal.SecurityIdentifier($binarySID,0)).Value
        }
    }
}
Function NormalizeAccounts
{
    param(
        [parameter(valuefrompipeline=$true)]
        $users
    )

    $users = $users.Trim()
    If ($users -eq "") {
        $splittedUsers = [Collections.Generic.List[String]] @()
    }
    Else {
        $splittedUsers = [Collections.Generic.List[String]] $users.Split(",")
    }

    $normalizedUsers = [Collections.Generic.List[String]] @()
    ForEach($splittedUser in $splittedUsers) {
        $sid = UserSearch $splittedUser
        If (!$sid) {
            Fail-Json $result "$splittedUser is not a valid user or group on the host machine or domain"
        }

        $normalizedUser = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
        $normalizedUsers.Add($normalizedUser)
    }

    return ,$normalizedUsers
}

$result = @{
    changed = $false
}

$params = Parse-Args $args

$name = Get-AnsibleParam -obj $params -name "name" -type "str" -failifempty $true
$state = Get-AnsibleParam -obj $params -name "state" -type "str" -default "present" -validateset "present","absent"

Try {
    $share = Get-SmbShare $name -ErrorAction SilentlyContinue
    If ($state -eq "absent") {
        If ($share) {
            Remove-SmbShare -Force -Name $name
            $result.changed = $true
        }
    }
    Else {
        $path = Get-AnsibleParam -obj $params -name "path" -type "path" -failifempty $true
        $description = Get-AnsibleParam -obj $params -name "description" -type "str" -default ""

        $permissionList = Get-AnsibleParam -obj $params -name "list" -type "bool" -default "no" -validateset "no","yes" -resultobj $result
        $folderEnum = if ($permissionList) { "Unrestricted" } else { "AccessBased" }

        $permissionRead = Get-AnsibleParam -obj $params -name "read" -type "str" -default "" | NormalizeAccounts
        $permissionChange = Get-AnsibleParam -obj $params -name "change" -type "str" -default "" | NormalizeAccounts
        $permissionFull = Get-AnsibleParam -obj $params -name "full" -type "str" -default "" | NormalizeAccounts
        $permissionDeny = Get-AnsibleParam -obj $params -name "deny" -type "str" -default "" | NormalizeAccounts

        $cachingMode = Get-AnsibleParam -obj $params -name "caching_mode" -type "str" -default "None" -validateSet "BranchCache","Documents","Manual","None","Programs", "Unkown"

        If (-Not (Test-Path -Path $path)) {
            Fail-Json $result "$path directory does not exist on the host"
        }

        # normalize path and remove slash at the end
        $path = (Get-Item $path).FullName -replace "\\$"

        # need to (re-)create share
        If (-not $share) {
            New-SmbShare -Name $name -Path $path
            $share = Get-SmbShare $name -ErrorAction SilentlyContinue

            $result.changed = $true
        }
        If ($share.Path -ne $path) {
            Remove-SmbShare -Force -Name $name

            New-SmbShare -Name $name -Path $path
            $share = Get-SmbShare $name -ErrorAction SilentlyContinue

            $result.changed = $true
        }

        # updates
        If ($share.Description -ne $description) {
            Set-SmbShare -Force -Name $name -Description $description
            $result.changed = $true
        }
        If ($share.FolderEnumerationMode -ne $folderEnum) {
            Set-SmbShare -Force -Name $name -FolderEnumerationMode $folderEnum
            $result.changed = $true
        }
        if ($share.CachingMode -ne $cachingMode) {
            Set-SmbShare -Force -Name $name -CachingMode $cachingMode
            Set-Attr $result "changed" $true;
        }

        # clean permissions that imply others
        ForEach ($user in $permissionFull) {
            $permissionChange.remove($user)
            $permissionRead.remove($user)
        }
        ForEach ($user in $permissionChange) {
            $permissionRead.remove($user)
        }

        # remove permissions
        $permissions = Get-SmbShareAccess -Name $name
        ForEach ($permission in $permissions) {
            If ($permission.AccessControlType -eq "Deny") {
                If (!$permissionDeny.Contains($permission.AccountName)) {
                    Unblock-SmbShareAccess -Force -Name $name -AccountName $permission.AccountName
                    $result.changed = $true
                }
            }
            ElseIf ($permission.AccessControlType -eq "Allow") {
                If ($permission.AccessRight -eq "Full") {
                    If (!$permissionFull.Contains($permission.AccountName)) {
                        Revoke-SmbShareAccess -Force -Name $name -AccountName $permission.AccountName
                        $result.changed = $true

                        Continue
                    }

                    # user got requested permissions
                    $permissionFull.remove($permission.AccountName)
                }
                ElseIf ($permission.AccessRight -eq "Change") {
                    If (!$permissionChange.Contains($permission.AccountName)) {
                        Revoke-SmbShareAccess -Force -Name $name -AccountName $permission.AccountName
                        $result.changed = $true

                        Continue
                    }

                    # user got requested permissions
                    $permissionChange.remove($permission.AccountName)
                }
                ElseIf ($permission.AccessRight -eq "Read") {
                    If (!$permissionRead.Contains($permission.AccountName)) {
                        Revoke-SmbShareAccess -Force -Name $name -AccountName $permission.AccountName
                        $result.changed = $true

                        Continue
                    }

                    # user got requested permissions
                    $permissionRead.Remove($permission.AccountName)
                }
            }
        }

        # add missing permissions
        ForEach ($user in $permissionRead) {
            Grant-SmbShareAccess -Force -Name $name -AccountName $user -AccessRight "Read"
            $result.changed = $true
        }
        ForEach ($user in $permissionChange) {
            Grant-SmbShareAccess -Force -Name $name -AccountName $user -AccessRight "Change"
            $result.changed = $true
        }
        ForEach ($user in $permissionFull) {
            Grant-SmbShareAccess -Force -Name $name -AccountName $user -AccessRight "Full"
            $result.changed = $true
        }
        ForEach ($user in $permissionDeny) {
            Block-SmbShareAccess -Force -Name $name -AccountName $user
            $result.changed = $true
        }
    }
}
Catch {
    Fail-Json $result "an error occurred when attempting to create share $name"
}

Exit-Json $result
