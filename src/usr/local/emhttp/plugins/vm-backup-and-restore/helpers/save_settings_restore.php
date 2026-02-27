<?php
header('Content-Type: application/json');

// Path to your shell script
$cmd = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/save_settings_restore.sh';

// --- Grab raw values ---
$location_of_backups            = $_GET['LOCATION_OF_BACKUPS'] ?? '';
$vms_to_restore                 = $_GET['VMS_TO_RESTORE'] ?? '';
$versions                       = $_GET['VERSIONS'] ?? '';
$restore_destination            = $_GET['RESTORE_DESTINATION'] ?? '';
$dry_run_restore                = $_GET['DRY_RUN_RESTORE'] ?? '';
$notifications_restore          = $_GET['NOTIFICATIONS_RESTORE'] ?? '';
$discord_webhook_url_restore    = $_GET['DISCORD_WEBHOOK_URL_RESTORE'] ?? '';
$pushover_user_key_restore      = $_GET['PUSHOVER_USER_KEY_RESTORE'] ?? '';

// --- Normalize LOCATION_OF_BACKUPS ---
if ($location_of_backups !== '') {
    $resolved = realpath($location_of_backups);
    if ($resolved !== false) {
        $location_of_backups = $resolved;
    }
}

// --- (Optional) Normalize RESTORE_DESTINATION ---
if ($restore_destination !== '') {
    $resolved = realpath($restore_destination);
    if ($resolved !== false) {
        $restore_destination = $resolved;
    }
}

// --- Build args array ---
$args = [
    $location_of_backups,
    $vms_to_restore,
    $versions,
    $restore_destination,
    $dry_run_restore,
    $notifications_restore,
    $discord_webhook_url_restore,
    $pushover_user_key_restore,
];

// Escape each argument for safety
$escapedArgs = array_map('escapeshellarg', $args);

// Build command string
$fullCmd = $cmd . ' ' . implode(' ', $escapedArgs);

// Execute
$process = proc_open($fullCmd, [
    1 => ['pipe', 'w'],
    2 => ['pipe', 'w']
], $pipes);

if (is_resource($process)) {
    $output = stream_get_contents($pipes[1]);
    $error  = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($process);

    echo trim($output)
        ? $output
        : json_encode(['status' => 'error', 'message' => trim($error) ?: 'No response from shell script']);
} else {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start process']);
}
