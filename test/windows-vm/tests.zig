const std = @import("std");
const vm = @import("vm_runtime");
test "Windows accepts the approved maintenance plan" {
    try vm.context.scenario("accept");
}
test "Windows undoes the maintenance plan" {
    try vm.context.scenario("undo");
}
test "Windows recovers verified power loss then undoes" {
    try vm.context.scenario("powercut-undo");
}
test "Windows recovers verified power loss then accepts" {
    try vm.context.scenario("powercut-accept");
}
test "Windows recovers power loss during apply" {
    try vm.context.scenario("powercut-apply");
}
