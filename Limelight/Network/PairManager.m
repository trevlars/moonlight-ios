//
//  PairManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "PairManager.h"
#import "CryptoManager.h"
#import "Utils.h"
#import "HttpResponse.h"
#import "HttpRequest.h"
#import "ServerInfoResponse.h"

#include <dispatch/dispatch.h>

@implementation PairManager {
    HttpManager* _httpManager;
    NSData* _clientCert;
    id<PairCallback> _callback;
}

- (id) initWithManager:(HttpManager*)httpManager clientCert:(NSData*)clientCert callback:(id<PairCallback>)callback {
    self = [super init];
    _httpManager = httpManager;
    _clientCert = clientCert;
    _callback = callback;
    return self;
}

- (void) main {
    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
    [_httpManager executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[_httpManager newServerInfoRequest:false]
                                               fallbackError:401 fallbackRequest:[_httpManager newHttpServerInfoRequest]]];
    if (serverInfoResp == nil) {
        [_callback pairFailed:@"Unable to connect to PC"];
        return;
    }
    if ([serverInfoResp isStatusOk]) {
        if ([[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
            [_callback pairFailed:@"You cannot pair while a previous session is still running on the host PC. Quit any running games or reboot the host PC, then try pairing again."];
        } else if (![[serverInfoResp getStringTag:@"PairStatus"] isEqual:@"1"]) {
            NSString* appversion = [serverInfoResp getStringTag:@"appversion"];
            if (appversion == nil) {
                [_callback pairFailed:@"Missing XML element"];
                return;
            }            
            [self initiatePair: [[appversion substringToIndex:1] intValue]];
        } else {
            [_callback alreadyPaired];
        }
    }
}

- (void) finishPairing:(UIBackgroundTaskIdentifier)bgId withError:(NSString*)errorMsg {
    if (bgId != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:bgId];
    }
    
    [_callback pairFailed:errorMsg];
}

- (void) finishPairing:(UIBackgroundTaskIdentifier)bgId withSuccess:(NSData*)derCertBytes {
    if (bgId != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:bgId];
    }
    
    [_callback pairSuccessful:derCertBytes];
}

// All codepaths must call finishPairing exactly once before returning!
- (void) initiatePair:(int)serverMajorVersion {
    Log(LOG_I, @"Pairing with generation %d server", serverMajorVersion);
    
    // Start a background task to help prevent the app from being killed
    // while pairing is in progress.
    UIBackgroundTaskIdentifier bgId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"Pairing PC" expirationHandler:^{
        Log(LOG_W, @"Background pairing time has expired!");
    }];
    
    NSString* PIN = [self generatePIN];
    NSData* salt = [self saltPIN:PIN];
    Log(LOG_I, @"PIN: %@, saltedPIN: %@", PIN, salt);
    [_callback showPIN:PIN];
    
    HttpResponse* pairResp = [[HttpResponse alloc] init];
    [_httpManager executeRequestSynchronously:[HttpRequest requestForResponse:pairResp withUrlRequest:[_httpManager newPairRequest:salt clientCert:_clientCert]]];
    if (![self verifyResponseStatus:pairResp]) {
        [self finishPairing:bgId withError:@"Pairing stage #1 failed"];
        return;
    }
    NSInteger pairedStatus;
    if (![pairResp getIntTag:@"paired" value:&pairedStatus] || !pairedStatus) {
        [self finishPairing:bgId withError:@"Pairing was declined by the target."];
        return;
    }
    
    NSString* plainCert = [pairResp getStringTag:@"plaincert"];
    if ([plainCert length] == 0) {
        [self finishPairing:bgId withError:@"Another pairing attempt is already in progress."];
        return;
    }
    
    // Pin the cert for TLS usage on this host
    NSData* derCertBytes = [CryptoManager pemToDer:[Utils hexToBytes:plainCert]];
    [_httpManager setServerCert:derCertBytes];
    
    CryptoManager* cryptoMan = [[CryptoManager alloc] init];
    NSData* aesKey;
    
    // Gen 7 servers use SHA256 to get the key
    int hashLength;
    if (serverMajorVersion >= 7) {
        aesKey = [cryptoMan createAESKeyFromSaltSHA256:salt];
        hashLength = 32;
    }
    else {
        aesKey = [cryptoMan createAESKeyFromSaltSHA1:salt];
        hashLength = 20;
    }
    
    NSData* randomChallenge = [Utils randomBytes:16];
    NSData* encryptedChallenge = [cryptoMan aesEncrypt:randomChallenge withKey:aesKey];
    
    HttpResponse* challengeResp = [[HttpResponse alloc] init];
    [_httpManager executeRequestSynchronously:[HttpRequest requestForResponse:challengeResp withUrlRequest:[_httpManager newChallengeRequest:encryptedChallenge]]];
    if (![self verifyResponseStatus:challengeResp] ||
        ![challengeResp getIntTag:@"paired" value:&pairedStatus] ||
        pairedStatus != 1) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        [self finishPairing:bgId withError:@"Pairing stage #2 failed"];
        return;
    }
    
    NSData* encServerChallengeResp = [Utils hexToBytes:[challengeResp getStringTag:@"challengeresponse"]];
    NSData* decServerChallengeResp = [cryptoMan aesDecrypt:encServerChallengeResp withKey:aesKey];
    
    NSData* serverResponse = [decServerChallengeResp subdataWithRange:NSMakeRange(0, hashLength)];
    NSData* serverChallenge = [decServerChallengeResp subdataWithRange:NSMakeRange(hashLength, 16)];
    
    NSData* clientSecret = [Utils randomBytes:16];
    NSData* challengeRespHashInput = [self concatData:[self concatData:serverChallenge with:[CryptoManager getSignatureFromCert:_clientCert]] with:clientSecret];
    NSData* challengeRespHash;
    if (serverMajorVersion >= 7) {
        challengeRespHash = [cryptoMan SHA256HashData: challengeRespHashInput];
    }
    else {
        challengeRespHash = [cryptoMan SHA1HashData: challengeRespHashInput];
    }
    NSData* challengeRespEncrypted = [cryptoMan aesEncrypt:challengeRespHash withKey:aesKey];
    
    HttpResponse* secretResp = [[HttpResponse alloc] init];
    [_httpManager executeRequestSynchronously:[HttpRequest requestForResponse:secretResp withUrlRequest:[_httpManager newChallengeRespRequest:challengeRespEncrypted]]];
    if (![self verifyResponseStatus:secretResp] ||
        ![secretResp getIntTag:@"paired" value:&pairedStatus] ||
        pairedStatus != 1) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        [self finishPairing:bgId withError:@"Pairing stage #3 failed"];
        return;
    }
    
    NSData* serverSecretResp = [Utils hexToBytes:[secretResp getStringTag:@"pairingsecret"]];
    NSData* serverSecret = [serverSecretResp subdataWithRange:NSMakeRange(0, 16)];
    NSData* serverSignature = [serverSecretResp subdataWithRange:NSMakeRange(16, 256)];
    
    if (![cryptoMan verifySignature:serverSecret withSignature:serverSignature andCert:[Utils hexToBytes:plainCert]]) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        [self finishPairing:bgId withError:@"Server certificate invalid"];
        return;
    }
    
    NSData* serverChallengeRespHashInput = [self concatData:[self concatData:randomChallenge with:[CryptoManager getSignatureFromCert:[Utils hexToBytes:plainCert]]] with:serverSecret];
    NSData* serverChallengeRespHash;
    if (serverMajorVersion >= 7) {
        serverChallengeRespHash = [cryptoMan SHA256HashData: serverChallengeRespHashInput];
    }
    else {
        serverChallengeRespHash = [cryptoMan SHA1HashData: serverChallengeRespHashInput];
    }
    if (![serverChallengeRespHash isEqual:serverResponse]) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        [self finishPairing:bgId withError:@"Incorrect PIN"];
        return;
    }
    
    NSData* clientPairingSecret = [self concatData:clientSecret with:[cryptoMan signData:clientSecret withKey:[CryptoManager readKeyFromFile]]];
    HttpResponse* clientSecretResp = [[HttpResponse alloc] init];
    [_httpManager executeRequestSynchronously:[HttpRequest requestForResponse:clientSecretResp withUrlRequest:[_httpManager newClientSecretRespRequest:[Utils bytesToHex:clientPairingSecret]]]];
    if (![self verifyResponseStatus:clientSecretResp] ||
        ![clientSecretResp getIntTag:@"paired" value:&pairedStatus] ||
        pairedStatus != 1) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        [self finishPairing:bgId withError:@"Pairing stage #4 failed"];
        return;
    }
    
    HttpResponse* clientPairChallengeResp = [[HttpResponse alloc] init];
    [_httpManager executeRequestSynchronously:[HttpRequest requestForResponse:clientPairChallengeResp withUrlRequest:[_httpManager newPairChallenge]]];
    if (![self verifyResponseStatus:clientPairChallengeResp] ||
        ![clientPairChallengeResp getIntTag:@"paired" value:&pairedStatus] ||
        pairedStatus != 1) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        [self finishPairing:bgId withError:@"Pairing stage #5 failed"];
        return;
    }
    
    [self finishPairing:bgId withSuccess:derCertBytes];
}

// Caller calls finishPairing for us on failure
- (BOOL) verifyResponseStatus:(HttpResponse*)resp {
    if (resp == nil) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        return false;
    } else if (![resp isStatusOk]) {
        [_httpManager executeRequestSynchronously:[HttpRequest requestWithUrlRequest:[_httpManager newUnpairRequest]]];
        return false;
    } else {
        return true;
    }
}

- (NSData*) concatData:(NSData*)data with:(NSData*)moreData {
    NSMutableData* concatData = [[NSMutableData alloc] initWithData:data];
    [concatData appendData:moreData];
    return concatData;
}

- (NSString*) generatePIN {
    NSString* PIN = [NSString stringWithFormat:@"%d%d%d%d",
                     arc4random() % 10, arc4random() % 10,
                     arc4random() % 10, arc4random() % 10];
    return PIN;
}

- (NSData*) saltPIN:(NSString*)PIN {
    NSMutableData* saltedPIN = [[NSMutableData alloc] initWithCapacity:20];
    [saltedPIN appendData:[Utils randomBytes:16]];
    [saltedPIN appendBytes:[PIN UTF8String] length:4];
    return saltedPIN;
}

@end
