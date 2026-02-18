<?php
header('Content-Type: application/json');

$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/backup.sh';

if (!is_file($script) || !is_executable($script)) {
    echo json_encode([
        'status' => 'error',
        'message' => 'Backup script missing or not executable'
    ]);
    exit;
}

$cmd = escapeshellcmd($script);
$output = [];
$return_var = 0;
exec($cmd, $output, $return_var);

echo json_encode([
    'status' => $return_var === 0 ? 'ok' : 'error',
    'message' => implode("\n", $output)
]);
