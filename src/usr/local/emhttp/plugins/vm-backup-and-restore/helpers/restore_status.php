<?php
header('Content-Type: application/json');

$lock = '/tmp/vm-backup-and-restore/restore_lock.txt';

echo json_encode([
  'running' => file_exists($lock)
]);
