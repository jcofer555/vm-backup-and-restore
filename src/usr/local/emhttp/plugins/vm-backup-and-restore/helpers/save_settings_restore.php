<?php
header('Content-Type: application/json');

// Path to your shell script
$cmd = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/save_settings_restore.sh';

// Grab arguments from query string
$args = [
    $_GET['RESTORE_LOCATION'] ?? '',
    $_GET['DRY_RUN_RESTORE'] ?? '',
    $_GET['ENABLE_NOTIFICATIONS_RESTORE'] ?? '',
];

// Escape each argument for safety
$escapedArgs = array_map('escapeshellarg', $args);

// Build command string
$fullCmd = $cmd . ' ' . implode(' ', $escapedArgs);

// Set up I/O pipes for stdout and stderr
$process = proc_open($fullCmd, [
    1 => ['pipe', 'w'], // stdout
    2 => ['pipe', 'w']  // stderr
], $pipes);

// Handle output
if (is_resource($process)) {
    $output = stream_get_contents($pipes[1]);
    $error  = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($process);

    // If output is valid JSON, echo it — otherwise return error
    if (trim($output)) {
        echo $output;
    } else {
        echo json_encode(['status' => 'error', 'message' => trim($error) ?: 'No response from shell script']);
    }
} else {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start process']);
}