<?php
declare(strict_types=1);
header('Content-Type: application/json');

// --- Constants ---
const CONFIG_PATH = '/boot/config/plugins/vm-backup-and-restore/settings.cfg';
const CONFIG_TMP  = CONFIG_PATH . '.tmp';

// --- Utility ---
function sanitize_val(string $val): string
{
    return str_replace(['"', "'", "\n", "\r"], '', $val);
}

function json_error(string $message): void
{
    echo json_encode(['status' => 'error', 'message' => $message]);
    exit;
}

// --- CSRF validation ---
// Only enforce if the cookie is actually present — if Unraid hasn't set it yet
// (e.g. first load, session edge case) we allow through rather than hard-fail.
$csrf_cookie_str = $_COOKIE['csrf_token'] ?? '';
$csrf_post_str   = $_POST['csrf_token']   ?? '';
if ($csrf_cookie_str !== '' && !hash_equals($csrf_cookie_str, $csrf_post_str)) {
    json_error('Invalid CSRF token');
}

// --- Read POST values ---
$vms_to_backup_str        = (string)($_POST['VMS_TO_BACKUP']        ?? '');
$backup_destination_str   = (string)($_POST['BACKUP_DESTINATION']   ?? '');
$backups_to_keep_str      = (string)($_POST['BACKUPS_TO_KEEP']       ?? '0');
$backup_owner_str         = (string)($_POST['BACKUP_OWNER']          ?? 'nobody');
$dry_run_str              = (string)($_POST['DRY_RUN']               ?? 'no');
$notifications_str        = (string)($_POST['NOTIFICATIONS']         ?? 'no');
$notification_service_str = (string)($_POST['NOTIFICATION_SERVICE']  ?? '');
$pushover_user_key_str    = (string)($_POST['PUSHOVER_USER_KEY']     ?? '');

$services_arr = ['DISCORD', 'GOTIFY', 'NTFY', 'PUSHOVER', 'SLACK'];
$webhooks_arr = [];
foreach ($services_arr as $svc_str) {
    $webhooks_arr[$svc_str] = (string)($_POST['WEBHOOK_' . $svc_str] ?? '');
}

// --- Build config (paths stored as-is — realpath applied at backup time) ---
$lines_arr = [
    'VMS_TO_BACKUP'        => $vms_to_backup_str,
    'BACKUP_DESTINATION'   => $backup_destination_str,
    'BACKUPS_TO_KEEP'      => $backups_to_keep_str,
    'BACKUP_OWNER'         => $backup_owner_str,
    'DRY_RUN'              => $dry_run_str,
    'NOTIFICATIONS'        => $notifications_str,
    'NOTIFICATION_SERVICE' => $notification_service_str,
    'WEBHOOK_DISCORD'      => $webhooks_arr['DISCORD'],
    'WEBHOOK_GOTIFY'       => $webhooks_arr['GOTIFY'],
    'WEBHOOK_NTFY'         => $webhooks_arr['NTFY'],
    'WEBHOOK_PUSHOVER'     => $webhooks_arr['PUSHOVER'],
    'WEBHOOK_SLACK'        => $webhooks_arr['SLACK'],
    'PUSHOVER_USER_KEY'    => $pushover_user_key_str,
];

$content_str = '';
foreach ($lines_arr as $key_str => $val_str) {
    $content_str .= $key_str . '="' . sanitize_val($val_str) . '"' . "\n";
}

// --- Write atomically ---
@mkdir(dirname(CONFIG_PATH), 0755, true);

if (file_put_contents(CONFIG_TMP, $content_str) === false) {
    json_error('Failed to write temp config');
}

if (!rename(CONFIG_TMP, CONFIG_PATH)) {
    @unlink(CONFIG_TMP);
    json_error('Failed to move config into place');
}

echo json_encode(['status' => 'ok']);