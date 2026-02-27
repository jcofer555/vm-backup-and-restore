<?php
header('Content-Type: application/json');

$cmd = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/save_settings.sh';

// --- Grab raw values ---
$vms_to_backup          = $_GET['VMS_TO_BACKUP'] ?? '';
$backup_destination     = $_GET['BACKUP_DESTINATION'] ?? '';
$backups_to_keep        = $_GET['BACKUPS_TO_KEEP'] ?? '';
$backup_owner           = $_GET['BACKUP_OWNER'] ?? '';
$dry_run                = $_GET['DRY_RUN'] ?? '';
$notifications          = $_GET['NOTIFICATIONS'] ?? '';
$discord_webhook_url    = $_GET['DISCORD_WEBHOOK_URL'] ?? '';
$pushover_user_key      = $_GET['PUSHOVER_USER_KEY'] ?? '';

// --- Normalize paths ---
if ($backup_destination !== '') {
    $resolved = realpath($backup_destination);
    if ($resolved !== false) {
        $backup_destination = $resolved;
    }
}

// --- Build args array ---
$args = [
    $vms_to_backup,
    $backup_destination,
    $backups_to_keep,
    $backup_owner,
    $dry_run,
    $notifications,
    $discord_webhook_url,
    $pushover_user_key,
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
