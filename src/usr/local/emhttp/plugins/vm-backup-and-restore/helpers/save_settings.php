<?php
header('Content-Type: application/json');

$config = '/boot/config/plugins/vm-backup-and-restore/settings.cfg';
$tmp    = $config . '.tmp';

// --- Read from POST ---
$vms_to_backup        = $_POST['VMS_TO_BACKUP']        ?? '';
$backup_destination   = $_POST['BACKUP_DESTINATION']   ?? '';
$backups_to_keep      = $_POST['BACKUPS_TO_KEEP']       ?? '0';
$backup_owner         = $_POST['BACKUP_OWNER']          ?? 'nobody';
$dry_run              = $_POST['DRY_RUN']               ?? 'no';
$notifications        = $_POST['NOTIFICATIONS']         ?? 'no';
$notification_service = $_POST['NOTIFICATION_SERVICE']  ?? '';
$pushover_user_key    = $_POST['PUSHOVER_USER_KEY']     ?? '';

$services    = ['DISCORD', 'GOTIFY', 'NTFY', 'PUSHOVER', 'SLACK'];
$webhookUrls = [];
foreach ($services as $svc) {
    $webhookUrls[$svc] = $_POST['WEBHOOK_' . $svc] ?? '';
}

// --- Normalize path ---
if ($backup_destination !== '') {
    $resolved = realpath($backup_destination);
    if ($resolved !== false) {
        $backup_destination = $resolved;
    }
}

// --- Sanitize helper: strip quotes and newlines ---
function sanitize(string $val): string {
    return str_replace(['"', "'", "\n", "\r"], '', $val);
}

// --- Build config lines ---
$lines = [
    'VMS_TO_BACKUP'        => $vms_to_backup,
    'BACKUP_DESTINATION'   => $backup_destination,
    'BACKUPS_TO_KEEP'      => $backups_to_keep,
    'BACKUP_OWNER'         => $backup_owner,
    'DRY_RUN'              => $dry_run,
    'NOTIFICATIONS'        => $notifications,
    'NOTIFICATION_SERVICE' => $notification_service,
    'WEBHOOK_DISCORD'      => $webhookUrls['DISCORD'],
    'WEBHOOK_GOTIFY'       => $webhookUrls['GOTIFY'],
    'WEBHOOK_NTFY'         => $webhookUrls['NTFY'],
    'WEBHOOK_PUSHOVER'     => $webhookUrls['PUSHOVER'],
    'WEBHOOK_SLACK'        => $webhookUrls['SLACK'],
    'PUSHOVER_USER_KEY'    => $pushover_user_key,
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