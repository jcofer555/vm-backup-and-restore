<?php
declare(strict_types=1);
header('Content-Type: text/plain');

const LOG_PATH = '/tmp/vm-backup-and-restore/vm-backup-and-restore.log';
const MAX_LINES = 500;

if (!file_exists(LOG_PATH)) {
    echo 'Backup & restore log not found';
    exit;
}

$lines_arr   = file(LOG_PATH, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$tail_arr    = array_slice($lines_arr, -MAX_LINES);
$reversed_arr = array_reverse($tail_arr);

echo implode("\n", $reversed_arr);
