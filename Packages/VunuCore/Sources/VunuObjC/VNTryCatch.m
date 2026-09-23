#import "VNTryCatch.h"

NSError * _Nullable VNTryCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
        info[@"ExceptionName"] = exception.name;
        return [NSError errorWithDomain:@"dev.nunu.vunu.objc-exception" code:1 userInfo:info];
    }
}
