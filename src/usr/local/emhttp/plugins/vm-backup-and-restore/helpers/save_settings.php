<?php
header('Content-Type: application/json');

// Path to your shell script
$cmd = '/usr/local/emhttp/plugins/automover/helpers/save_settings.sh';

// Grab arguments from query string
$args = [
    $_GET['VM_NAME'] ?? '',
    $_GET['DRY_RUN'] ?? '',
    $_GET['ALLOW_DURING_PARITY'] ?? '',
    $_GET['AUTOSTART'] ?? '',
    $_GET['CRON_MODE'] ?? '',
    $_GET['MINUTES_FREQUENCY'] ?? '',
    $_GET['HOURLY_FREQUENCY'] ?? '',
    $_GET['DAILY_TIME'] ?? '',
    $_GET['WEEKLY_DAY'] ?? '',
    $_GET['WEEKLY_TIME'] ?? '',
    $_GET['MONTHLY_DAY'] ?? '',
    $_GET['MONTHLY_TIME'] ?? '',
    $_GET['CUSTOM_CRON'] ?? '',
    $_GET['CRON_EXPRESSION'] ?? '',
    $_GET['ENABLE_NOTIFICATIONS'] ?? '',
    $_GET['WEBHOOK_URL'] ?? '',
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