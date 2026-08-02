# ResetNightmare

Proof-of-concept (POC) tool for **ResetNightmare (CVE-2026-27912)**.

ResetNightmare is a validation flaw in the Kerberos Change Password protocol that allows for resetting the password of any target user/computer account, without knowing the current one. 
The attack requires an unpatched domain controller, and the ability to write a `userPrincipalName` (UPN) on any
account you control.
Alternatively, the vulnerability can also be abused by an attacker having the ability to create new users/computers in any OU, as creating a user/computer allows you to get GenericWrite permissions over it.

## Attack flow
This script automates the full attack flow and cleans up after itself.
The attack flow is as follows:
1. The attacker has a user or computer that they can write a UPN to. This can either be supplied, or created, using `-CreateNewPath`.
2. The attacker sets the UPN of the account they control to the `sAMAccountName` of the target, e.g. "Administrator".
3. The attacker can then request a TGT for the "Administrator" user name, with a name type of `NT-ENTERPRISE`. This TGT will be requested to the `kadmin/changepw` SPN.
4. The attacker clears their own UPN, leaving only the target with a UPN that resolved to themself. 
5. The attacker then uses the TGT they have to reset the password for the "Administrator" user, without ever knowing the previous value.
6. If the attack succeeds, the target's password has been changed, and the attacker can now authenticate using the new credentials.

Both user and computer accounts can be targeted.

## Requirements

- Windows with PowerShell.
- The **ActiveDirectory** PowerShell module.
- The script uses Rubeus.exe, tested with Rubeus compiled against .NET Framework 4.6.2.
  Place it in the current directory, or point to it with `-RubeusPath`.
- Either:
  - A domain account you control and can write a UPN to.
  - Permission
  to create accounts in an OU/Container (specified with `-CreateNewPath`).
- An unpatched DC to target. Can be specified with `-DC`.

## Usage

Dot-source the script to load the function, then call it:

```powershell
. .\ResetNightmare.ps1

Invoke-ResetNightmare `
    -TargetAccount "victim" `
    -TargetNewPassword "NewP@ssw0rd!" `
    -UPNUser "controlledUser" `
    -UPNUserPassword "ControlledP@ss!"
```

### Targeting a computer account

Use the `sAMAccountName` (ending with `$`) for `-TargetAccount`:

```powershell
Invoke-ResetNightmare `
    -TargetAccount 'server$' `
    -TargetNewPassword "NewP@ssw0rd!" `
    -UPNUser "controlledUser" `
    -UPNUserPassword "ControlledP@ss!"
```

### Creating a new controlled account

If you have permission to create objects in an OU/Container, you can specify the DN to the OU/Container using `-CreateNewPath`. When it's specified, `-UPNUser` and `-UPNUserPassword` are treated as the credentials of the account to create, instead of an existing account in the domain:

```powershell
Invoke-ResetNightmare `
    -TargetAccount "victim" `
    -TargetNewPassword "NewP@ssw0rd!" `
    -UPNUser "attackerAcct" `
    -UPNUserPassword "AttackerP@ss!" `
    -CreateNewPath "OU=Temp,DC=demo,DC=lab"
```

Add `-Computer` to create/use a computer account instead of a user account.

## Parameters

| Parameter             | Required | Description                                                                                                          |
| --------------------- | -------- | ------------------------------------------------------------------------------------------------------------------ |
| `-TargetAccount`      | Yes      | The `sAMAccountName` of the account to target with the password reset. Ensure to include the trailing `$` if targeting a computer account.           |
| `-TargetNewPassword`  | Yes      | The new password to set for the target account.                                                                    |
| `-UPNUser`            | Yes      | The account to which the you can write a UPN, or the account to create if `-CreateNewPath` is specified.           |
| `-UPNUserPassword`    | Yes      | Cleartext password for `-UPNUser`.                                                                                  |
| `-Computer`           | No       | Treat `-UPNUser` as a computer account (and create a computer account when combined with `-CreateNewPath`).         |
| `-RubeusPath`         | No       | The path to the Rubeus executable. Default is ".\Rubeus.exe".                                                       |
| `-SupportedEncryption`| No       | The supported encryption type for the TGT. The default value is "AES256" and should work for most cases. If changing this is needed, the supported values are: <br>DES\|RC4\|AES128\|AES256                                     |
| `-CreateNewPath`      | No       | DistinguishedName to an OU/Container where you have permissions to create objects. If specified, the `-UPNUser` and `-UPNUserPassword` parameters will be the credentials of the user to create, instead of using an existing user.    |
| `-DC`                 | No       | Name of the DC to operate against. This is automatically resolved if not specified.                                   |

> **DISCLAIMER**\
> This content is provided for educational and informational purposes only. It is intended to promote awareness and responsible remediation of security vulnerabilities that may exist on systems you own or are authorized to test. Unauthorized use of this information for malicious purposes, exploitation, or unlawful access is strictly prohibited. The authors do not endorse or condone any illegal activity and disclaim any liability arising from misuse of the material. Additionally, the authors do not guarantee the accuracy or completeness of the content and assume no liability for any damages resulting from its use.