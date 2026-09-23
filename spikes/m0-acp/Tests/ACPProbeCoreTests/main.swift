import Foundation

runJSONRPCTests()
runACPConnectionTests()
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
