<?php
header('Content-Type: application/json');

// Run virsh safely
$cmd = "virsh list --all --name 2>/dev/null";
exec($cmd, $output, $ret);

// Normalize: remove empty lines
$vms = array_filter(array_map('trim', $output), fn($v) => $v !== '');

echo json_encode([
    'vms' => array_values($vms)
]);
