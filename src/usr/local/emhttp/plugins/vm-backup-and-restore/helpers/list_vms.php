<?php

declare(strict_types=1);
header('Content-Type: application/json');

$output_arr = [];
exec('virsh list --all --name 2>/dev/null', $output_arr, $ret_int);

$vms_arr = array_values(
    array_filter(
        array_map('trim', $output_arr),
        static fn(string $v): bool => $v !== ''
    )
);

echo json_encode([
    'vms' => $vms_arr,
]);
