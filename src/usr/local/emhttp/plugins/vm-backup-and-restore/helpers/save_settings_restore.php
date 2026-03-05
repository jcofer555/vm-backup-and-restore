<?php
header('Content-Type: application/json');

$config = '/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg';
$tmp    = $config . '.tmp';

// --- Read from POST ---
$location_of_backups          = $_POST['LOCATION_OF_BACKUPS']          ?? '';
$vms_to_restore               = $_POST['VMS_TO_RESTORE']               ?? '';
$versions                     = $_POST['VERSIONS']                     ?? '';
$restore_destination          = $_POST['RESTORE_DESTINATION']          ?? '/mnt/user/domains';
$dry_run_restore              = $_POST['DRY_RUN_RESTORE']              ?? 'no';
$notifications_restore        = $_POST['NOTIFICATIONS_RESTORE']        ?? 'no';
$notification_service_restore = $_POST['NOTIFICATION_SERVICE_RESTORE'] ?? '';
$pushover_user_key_restore    = $_POST['PUSHOVER_USER_KEY_RESTORE']    ?? '';

$services    = ['DISCORD', 'GOTIFY', 'NTFY', 'PUSHOVER', 'SLACK'];
$webhookUrls = [];
foreach ($services as $svc) {
    $webhookUrls[$svc] = $_POST['WEBHOOK_' . $svc . '_RESTORE'] ?? '';
}

// --- Normalize paths ---
if ($location_of_backups !== '') {
    $resolved = realpath($location_of_backups);
    if ($resolved !== false) {
        $location_of_backups = $resolved;
    }
}

if ($restore_destination !== '') {
    $resolved = realpath($restore_destination);
    if ($resolved !== false) {
        $restore_destination = $resolved;
    }
}

// --- Sanitize helper: strip quotes and newlines ---
function sanitize(string $val): string {
    return str_replace(['"', "'", "\n", "\r"], '', $val);
}

// --- Build config lines ---
$lines = [
    'LOCATION_OF_BACKUPS'          => $location_of_backups,
    'VMS_TO_RESTORE'               => $vms_to_restore,
    'VERSIONS'                     => $versions,
    'RESTORE_DESTINATION'          => $restore_destination,
    'DRY_RUN_RESTORE'              => $dry_run_restore,
    'NOTIFICATIONS_RESTORE'        => $notifications_restore,
    'NOTIFICATION_SERVICE_RESTORE' => $notification_service_restore,
    'WEBHOOK_DISCORD_RESTORE'      => $webhookUrls['DISCORD'],
    'WEBHOOK_GOTIFY_RESTORE'       => $webhookUrls['GOTIFY'],
    'WEBHOOK_NTFY_RESTORE'         => $webhookUrls['NTFY'],
    'WEBHOOK_PUSHOVER_RESTORE'     => $webhookUrls['PUSHOVER'],
    'WEBHOOK_SLACK_RESTORE'        => $webhookUrls['SLACK'],
    'PUSHOVER_USER_KEY_RESTORE'    => $pushover_user_key_restore,
];

$content = '';
foreach ($lines as $key => $val) {
    $content .= $key . '="' . sanitize($val) . '"' . "\n";
}

// --- Write atomically ---
@mkdir(dirname($config), 0755, true);

if (file_put_contents($tmp, $content) === false) {
    echo json_encode(['status' => 'error', 'message' => 'Failed to write temp config']);
    exit;
}

if (!rename($tmp, $config)) {
    @unlink($tmp);
    echo json_encode(['status' => 'error', 'message' => 'Failed to move config into place']);
    exit;
}

echo json_encode(['status' => 'ok']);