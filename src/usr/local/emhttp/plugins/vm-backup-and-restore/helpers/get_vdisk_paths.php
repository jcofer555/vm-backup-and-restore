<?php
header('Content-Type: application/json');

$vms = $_POST['vms'] ?? [];

if (!is_array($vms)) {
    $vms = explode(',', $vms);
}

$result = [];

foreach ($vms as $vm) {
    $vm = trim($vm);
    if ($vm === '') continue;

    $xmlPath = "/etc/libvirt/qemu/$vm.xml";

    if (!file_exists($xmlPath)) {
        $result[$vm] = ["error" => "XML not found"];
        continue;
    }

    $xml = simplexml_load_file($xmlPath);
    if (!$xml) {
        $result[$vm] = ["error" => "Failed to parse XML"];
        continue;
    }

    $vdisks = [];
    foreach ($xml->devices->disk as $disk) {
        if ((string)$disk['device'] === 'disk' && isset($disk->source['file'])) {
            $vdisks[] = (string)$disk->source['file'];
        }
    }

    $result[$vm] = $vdisks;
}

echo json_encode($result);
