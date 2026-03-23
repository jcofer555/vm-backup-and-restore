<?php

declare(strict_types=1);
header('Content-Type: application/json');

$vms_raw = $_POST['vms'] ?? [];

$vms_arr = is_array($vms_raw)
    ? $vms_raw
    : explode(',', (string)$vms_raw);

$result_arr = [];

foreach ($vms_arr as $vm_raw) {
    $vm_str = trim((string)$vm_raw);
    if ($vm_str === '') {
        continue;
    }

    $xml_path_str = "/etc/libvirt/qemu/$vm_str.xml";

    if (!file_exists($xml_path_str)) {
        $result_arr[$vm_str] = ['error' => 'XML not found'];
        continue;
    }

    $xml_obj = simplexml_load_file($xml_path_str);
    if ($xml_obj === false) {
        $result_arr[$vm_str] = ['error' => 'Failed to parse XML'];
        continue;
    }

    $vdisks_arr = [];
    foreach ($xml_obj->devices->disk as $disk_obj) {
        if ((string)$disk_obj['device'] === 'disk' && isset($disk_obj->source['file'])) {
            $vdisks_arr[] = (string)$disk_obj->source['file'];
        }
    }

    $result_arr[$vm_str] = $vdisks_arr;
}

echo json_encode($result_arr);
