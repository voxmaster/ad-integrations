# Run this script with administrator privileges
# This script uses Suprema Biostar2 cloud API
# This script matches email address filed from Active Directory user and from Biostar2 account, and than makes some profile changes or provisioning
# If you like this script: star it 
# If you want to chage it: fork it 
# If you want me to adopt this script for you: contact me via github (voxmaster) or https://www.upwork.com/fl/oleksiimarchenko9
# Set basic variables
$adBiostarGroup1 = Get-ADGroup "Biostar2-Office1-employees"       # Users from this Active Directory group will be proceed in script 
$adBiostarGroup2 = Get-ADGroup "Biostar2-Office2-employees"    # Users from this Active Directory group will be proceed in script 
$adSearchBase = "OU=Accounts,OU=YOUR_COMPANY,DC=domain,DC=local"   # LDAP search base
$lastUsedID = 201   # First ID that will be checked
$biostarInitialUserGroup1ID = 1118     # Biostar2 User group that will be matched to $adBiostarGroup1. It will only be used when creating
$biostarInitialUserGroup2ID = 1119     # Biostar2 User group that will be matched to $adBiostarGroup2. It will only be used when creating (Because of a user can be in single user group only, the last id will be used)
$biostarInitialAccessGroup1ID = 1      # Biostar2 Access group that will be matched to $adBiostarGroup1. It will only be used when creating
$biostarInitialAccessGroup2ID = 2      # Biostar2 Access group that will be matched to $adBiostarGroup2. It will only be used when creating
$isBiostarFullAccountUpdateCycle = $false   # this parameter toggle full profile update from AD. WARNING: It takes a very long time!
$biostarLoginCreds = @{
    "name" = "YOUR_CLOUD_SUBDOMAIN"
    "password" = "YOUR_PASSWORD"
    "user_id" = "YOUR_LOGIN"
}   # This credentials will be used to connect to biostar2 API 

# Get users from AD
$adBiostarUsers = Get-ADUser -Filter {memberOf -RecursiveMatch $adBiostarGroup1.DistinguishedName -or memberOf -RecursiveMatch $adBiostarGroup2.DistinguishedName} -SearchBase $adSearchBase -Properties EmailAddress, Mobile, memberOf
$biostarPresentUsersList = @(); $biostarFastUpdatedUsersList = @(); $biostarFullyUpdatedUsersList = @(); $biostarCreatedUsersList = @(); $biostarSetAccountsActive = @(); $biostarSetAccountsInactive = @()

# Log in Biostar2 API and get current users
Write-Host -NoNewline "`nLogging in Biotar2 API... "
try { Write-Host -ForegroundColor Green (Invoke-WebRequest -Uri "https://api.biostar2.com:443/v2/login" -SessionVariable biostarAPIwebSession -Method "POST" -Body $biostarLoginCreds).StatusDescription "!" }
catch { Write-Host -ForegroundColor Red "Can not login to biostar2 API"; pause; Exit }
Write-Host -NoNewline "`nGetting current Biostar2 accounts... "
$biostarAPIcurrentAccounts = Invoke-RestMethod -Uri "https://api.biostar2.com:443/v2/users?limit=9999&offset=0" -Method 'GET' -WebSession $biostarAPIwebSession
Write-Host -ForegroundColor Green "OK !"
# Write-Host -ForegroundColor DarkYellow "`nDEBUG: Found users in AD:`n" $adBiostarUsers.Name
# Write-Host -ForegroundColor DarkYellow "DEBUG: Occupied IDs:" $biostarAPIcurrentAccounts.records.user_id

# Biostar2 does not generate new free id automatically, so this function searches free ids starting from  $lastUsedID
Function getFreeIds ($amountToAllocate, $lastFreeID) {
    # Write-Host -ForegroundColor DarkYellow "DEBUG: last free ID:" $lastFreeID
    # Write-Host -ForegroundColor DarkYellow "DEBUG: amount:" $amountToAllocate
    $freeFound = 0
    $freeIDs = @()
    Foreach ($item in $biostarAPIcurrentAccounts.records.user_id) {
        # Write-Host -ForegroundColor DarkYellow "DEBUG: Skipping item:" $item
        if ($lastFreeID -le $item) {
            While($freeFound -lt $amountToAllocate -and $lastFreeID -ne $item) {
                $freeFound = $freeFound + 1
                $freeIDs += $lastFreeID
                # Write-Host -ForegroundColor DarkYellow "DEBUG: last free ID"  $lastFreeID
                $lastFreeID = $lastFreeID + 1
            }
            if ($lastFreeID -eq $item) {
                $lastFreeID = $lastFreeID + 1
            }
            if ($freeFound -ge $amountToAllocate) {
                break
            }
        }
    }
    # Write-Host -ForegroundColor DarkYellow "DEBUG: Free IDs:" $freeIDs
    return $freeIDs
}

# Check if user account is present in Biostar2 by email field
Function isPresentInBiostar ($email) {
    Foreach ($biostarAccount in $biostarAPIcurrentAccounts.records) {
        if ($biostarAccount.email -ieq $email) {
            [hashtable]$return = @{}
            $return.present = $true
            $return.id = $biostarAccount.user_id
            return $return
        }
    }
    [hashtable]$return = @{}
    $return.present = $false
}

# Check if user email field is present
Foreach ($adUser in $adBiostarUsers) {
    if ($adUser.EmailAddress) {} else {
        Write-Host "WARNING: $($adUser.Name)'s `t- e-mail is blank. Won't be created in Biostar2 " -ForegroundColor Red
        Write-Host "NOTE: To create $($adUser.Name)'s account in Biostar2 do it manually or fill email field " -ForegroundColor DarkYellow
        $confirmation = Read-Host -ForegroundColor Cyan "Are you wish to continue? [y/n]"
        while($confirmation -ne "y") {
            if ($confirmation -eq 'n') { exit }
            $confirmation = Read-Host -ForegroundColor Cyan "Are you wish to continue? [y/n]"
        }
    }
}

# Main part of user update and creation via api
Write-Host -ForegroundColor Cyan "`nProcessing Biostar2 accounts..."
Foreach ($adUser in $adBiostarUsers) {
    if ($adUser.EmailAddress) {
        # Write-Host -ForegroundColor DarkYellow "DEBUG: " "$($adUser.Name) `t- Proceeding..."
        $biostarUserPresence = $(isPresentInBiostar ($adUser.EmailAddress))
        
        if ($biostarUserPresence.id) {
            if ($adUser.Enabled) {$biostarAPIuserStatus = "AC"; $biostarSetAccountsActive += @{"user_id" = $biostarUserPresence.id }; $biostarFastUpdatedUsersList +=$adUser.Name } else {$biostarAPIuserStatus = "IN"; $biostarSetAccountsInactive += @{"user_id" = $biostarUserPresence.id }; $biostarFastUpdatedUsersList +=$adUser.Name  }
        } else {}

        if ($biostarUserPresence.present) {
            $biostarPresentUsersList += $adUser.Name
            # Write-Host -ForegroundColor DarkYellow "DEBUG: " "$($adUser.Name)'s account already present in Biostar2"
            # In this case we can update already present user in this case we GET profile, change some fields and PUT it back to profile:
            if ($isBiostarFullAccountUpdateCycle) {
                $biostarAPIupdateUserProfileRequest = Invoke-RestMethod -Uri "https://api.biostar2.com:443/v2/users/$($biostarUserPresence.id)" -Method 'GET' -WebSession $biostarAPIwebSession
                $biostarAPIupdateUserProfileRequest.name = $adUser.Name
                $biostarAPIupdateUserProfileRequest.status = $biostarAPIuserStatus
                try {$biostarAPIupdateUserProfileRequest.phone_number = "$($adUser.Mobile -replace '\D','' )" } catch {}
                $biostarAPIupdateUserProfileRequest = $biostarAPIupdateUserProfileRequest | ConvertTo-Json
                # Write-Host -ForegroundColor DarkYellow "`nDEBUG: " $biostarAPIupdateUserProfileRequest "`n"
                try {
                    $biostar2apiFullyUpdateUserRequest = Invoke-RestMethod -Uri "https://api.biostar2.com:443/v2/users/$($biostarUserPresence.id)" -Method 'PUT' -WebSession $biostarAPIwebSession -Body $biostarAPIupdateUserProfileRequest -ContentType "application/json"
                    Write-Host -ForegroundColor Green "$($adUser.Name) full profile update $($biostar2apiFullyUpdateUserRequest.status_code)"
                    $biostarFullyUpdatedUsersList += $adUser.Name
                }
                catch {
                    $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json
                    Write-Host -ForegroundColor Red "$($adUser.Name) Updating error! Reason:" $errorMessage.message
                }
            } else {}
        } else {
            # If user account does not exists - It is created
            # Write-Host -ForegroundColor DarkYellow "DEBUG: " "$($adUser.Name) `t- Will be created"
            # Write-Host -ForegroundColor DarkYellow "DEBUG: " "Forming params for new user"
            # Write-Host -ForegroundColor DarkYellow "DEBUG: " "sending id:" $lastUsedID
            # Set user group:
            $biostarAPIinitialAccessGroups = @()
            switch -Wildcard ($adUser.memberOf) {
                "*$($adBiostarGroup1.DistinguishedName)*" {
                    $biostarAPIuserGroupID = $biostarInitialUserGroup1ID
                    $biostarAPIinitialAccessGroups += @{"id" = $biostarInitialAccessGroup1ID}
                }
                "*$($adBiostarGroup2.DistinguishedName)*" {
                    $biostarAPIuserGroupID = $biostarInitialUserGroup2ID
                    $biostarAPIinitialAccessGroups += @{"id" = $biostarInitialAccessGroup2ID}
                }
            }
            # Get free id:
            $freeId = (getFreeIds 1 $lastUsedID)[0]
            $lastUsedID = $freeId + 1
            # Create user account profile data:
            $biostarAPIcreateUserProfile = @{
                "user_id" = "$freeId"
                "access_groups" = $biostarAPIinitialAccessGroups
                "email" = "$($adUser.EmailAddress)"
                "name" = "$($adUser.Name)"
                "phone_number" = "$($adUser.Mobile -replace '\D','')"
                "status" = "$biostarAPIuserStatus"
                "start_datetime" = "2019-01-01T00:00:00.00Z"
                "expiry_datetime" = "2030-01-01T00:00:00.00Z"
                "security_level" = "DEFAULT"
                "user_group" = @{"id" = $biostarAPIuserGroupID}
            } | ConvertTo-Json
            # Write-Host -ForegroundColor DarkYellow "DEBUG: biostarUserJSON:`n" $biostarAPIcreateUserProfile
            try {
                $biostarAPIcreateUserRequest =  Invoke-RestMethod -Uri "https://api.biostar2.com:443/v2/users" -Method 'Post' -WebSession $biostarAPIwebSession -Body $biostarAPIcreateUserProfile -ContentType "application/json"
                Write-Host -ForegroundColor Green "$($adUser.Name) - $($biostarAPIcreateUserRequest.status_code) with access groups IDs:" $biostarAPIinitialAccessGroups.id
                $biostarCreatedUsersList += $adUser.Name
            }
            catch {
                $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json
                Write-Host -ForegroundColor Red "$($adUser.Name) Creating error! Reason:" $errorMessage.message
            }
        }

    } else {
        Write-Host "WARNING: $($adUser.Name)'s e-mail is blank. Biostar2 user account not created!" -ForegroundColor Red
    }
}

# Batch Deactivating users:
    $biostarAPIBatchDeactivateUsersHT = @{
        "status" = "IN"
        "users" = $biostarSetAccountsInactive
    } | ConvertTo-Json
    try {
        $biostarAPIsetInactiveUsersRequest = Invoke-RestMethod -Uri "https://api.biostar2.com:443/v2/users/update" -Method 'POST' -WebSession $biostarAPIwebSession -Body $biostarAPIBatchDeactivateUsersHT -ContentType "application/json"
        Write-Host -ForegroundColor Green "Batch user deactivation action is $($biostarAPIsetInactiveUsersRequest.status_code) !"
    } catch {
        $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json
        Write-Host -ForegroundColor Red "Batch user deactivation error! Reason:" $errorMessage.message
    }

# Batch Activating users:
    $biostarAPIbatchActivateUsersHT = @{
        "status" = "AC"
        "users" = $biostarSetAccountsActive
    } | ConvertTo-Json
    try {
        $biostarAPIsetActiveUsersRequest = Invoke-RestMethod -Uri "https://api.biostar2.com:443/v2/users/update" -Method 'POST' -WebSession $biostarAPIwebSession -Body $biostarAPIbatchActivateUsersHT -ContentType "application/json"
        Write-Host -ForegroundColor Green "Batch user activation action is $($biostarAPIsetActiveUsersRequest.status_code) !"
    } catch {
        $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json
        Write-Host -ForegroundColor Red "Batch user activation error! Reason:" $errorMessage.message
    }

# Write-Host -Separator "`n" -ForegroundColor DarkYellow "`nDEBUG: Users that created in Biostar2: " $biostarCreatedUsersList
# Write-Host -Separator "`n" -ForegroundColor DarkYellow "`nDEBUG: Users that already present in Biostar2: " $biostarPresentUsersList
# Write-Host -Separator "`n" -ForegroundColor DarkYellow "`nDEBUG: Users that was fast updated in Biostar2: " $biostarFastUpdatedUsersList
# Write-Host -Separator "`n" -ForegroundColor DarkYellow "`nDEBUG: Users that was fully updated in Biostar2: " $biostarFullyUpdatedUsersList
Write-Host "`n`n`n"
