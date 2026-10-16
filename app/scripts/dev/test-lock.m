// test-lock lock|unlock: stands in for the Mac's screen lock for an OmacVM
// QEMU started with OMACVM_TEST_LOCK_HOOK=1 (#428): it posts the distributed
// notification org.omacvm.test.lock or org.omacvm.test.unlock, which only
// such a QEMU listens to. Nothing is locked; no other app reacts.
//
//   clang -fobjc-arc -framework Foundation test-lock.m -o test-lock
#import <Foundation/Foundation.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "lock") && strcmp(argv[1], "unlock"))) {
            fprintf(stderr, "usage: test-lock lock|unlock\n");
            return 2;
        }
        NSString *name = [NSString stringWithFormat:@"org.omacvm.test.%s", argv[1]];
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name
                                                                       object:nil
                                                                     userInfo:nil
                                                           deliverImmediately:YES];
    }
    return 0;
}
