$objs = Get-ADObject -LDAPFilter '(|(objectClass=user)(objectClass=computer))' -Properties sAMAccountName, userPrincipalName
$sam  = @{}; $objs | Where-Object sAMAccountName | ForEach-Object { $sam[$_.sAMAccountName.ToLower()] = $_.sAMAccountName }
$objs | Where-Object userPrincipalName | ForEach-Object {
  $k = $_.userPrincipalName.ToLower()
  if ($sam.ContainsKey($k) -and $sam[$k] -ne $_.sAMAccountName) {
    "{0}  (UPN '{1}')  impersonates  {2}" -f $_.sAMAccountName, $_.userPrincipalName, $sam[$k]
  }
}