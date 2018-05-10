test_cli_can_run() {
    kafka
    assert kafka
}

test_show_status() {
    kafka status
    assert kafka status
}

test_start_kafka() {
    kafka start
    assert kafka start
}