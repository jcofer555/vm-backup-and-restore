<?php
header('Content-Type: application/json');

$id = $argv[1] ?? ($_GET['id'] ?? ($_POST['id'] ?? ''));

if (!$id) {
    http_response_code(400);
    echo json_encode(['error' => 'Missing schedule id']);
    exit;
}

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    http_response_code(404);
    echo json_encode(['error' => 'Schedule not found']);
    exit;
}

// Unescape SETTINGS before decoding JSON
$rawSettings = stripslashes($schedules[$id]['SETTINGS'] ?? '');
$settings = json_decode($rawSettings, true);
if (!is_array($settings)) $settings = [];

// Export settings as environment variables
foreach ($settings as $k => $v) {
    putenv($k . '=' . (string)$v);
}
putenv("SCHEDULE_ID=$id");

// Run the backup script in the background
$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/scheduled_backup.sh';
exec("nohup /bin/bash $script &");

// Return JSON immediately
echo json_encode(['started' => true, 'id' => $id]);
