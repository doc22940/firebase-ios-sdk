/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#import <OCMock/OCMock.h>
#import "FBLPromise+Testing.h"
#import "FIRInstallationsItem+Tests.h"

#import "FIRInstallations.h"
#import "FIRInstallationsAPIService.h"
#import "FIRInstallationsErrorUtil.h"
#import "FIRInstallationsIDController.h"
#import "FIRInstallationsIIDStore.h"
#import "FIRInstallationsStore.h"
#import "FIRInstallationsStoredAuthToken.h"

@interface FIRInstallationsIDController (Tests)
- (instancetype)initWithGoogleAppID:(NSString *)appID
                            appName:(NSString *)appName
                 installationsStore:(FIRInstallationsStore *)installationsStore
                         APIService:(FIRInstallationsAPIService *)APIService
                           IIDStore:(FIRInstallationsIIDStore *)IIDStore;
@end

@interface FIRInstallationsIDControllerTests : XCTestCase
@property(nonatomic) FIRInstallationsIDController *controller;
@property(nonatomic) id mockInstallationsStore;
@property(nonatomic) id mockAPIService;
@property(nonatomic) id mockIIDStore;
@property(nonatomic) NSString *appID;
@property(nonatomic) NSString *appName;
@end

@implementation FIRInstallationsIDControllerTests

- (void)setUp {
  self.appID = @"appID";
  self.appName = @"appName";
  self.mockInstallationsStore = OCMClassMock([FIRInstallationsStore class]);
  self.mockAPIService = OCMClassMock([FIRInstallationsAPIService class]);
  self.mockIIDStore = OCMClassMock([FIRInstallationsIIDStore class]);

  self.controller =
      [[FIRInstallationsIDController alloc] initWithGoogleAppID:self.appID
                                                        appName:self.appName
                                             installationsStore:self.mockInstallationsStore
                                                     APIService:self.mockAPIService
                                                       IIDStore:self.mockIIDStore];
}

- (void)tearDown {
  self.controller = nil;
  self.mockIIDStore = nil;
  self.mockAPIService = nil;
  self.mockInstallationsStore = nil;
  self.appID = nil;
  self.appName = nil;
}

#pragma mark - Get Installation

- (void)testGetInstallationItem_WhenFIDExists_ThenItIsReturned {
  FIRInstallationsItem *storedInstallations =
      [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallations]);

  // Don't expect FIRInstallationIDDidChangeNotification to be sent.
  XCTestExpectation *notificationExpectation = [self installationIDDidChangeNotificationExpectation];
  notificationExpectation.inverted = YES;

  FBLPromise<FIRInstallationsItem *> *promise = [self.controller getInstallationItem];
  XCTAssert(FBLWaitForPromisesWithTimeout(0.5));

  XCTAssertNil(promise.error);
  XCTAssertEqual(promise.value, storedInstallations);

  OCMVerifyAll(self.mockInstallationsStore);
  [self waitForExpectations:@[ notificationExpectation ] timeout:0.5];
}

- (void)testGetInstallationItem_WhenNoFIDAndNoIID_ThenFIDIsCreatedAndRegistered {
  // 1. Stub store get installation.
  [self expectInstallationsStoreGetInstallationNotFound];

  // 2. Stub store save installation.
  __block FIRInstallationsItem *createdInstallation;

  OCMExpect([self.mockInstallationsStore
                saveInstallation:[OCMArg checkWithBlock:^BOOL(FIRInstallationsItem *obj) {
                  [self assertValidCreatedInstallation:obj];

                  createdInstallation = obj;
                  return YES;
                }]])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 3. Stub API register installation.
  // 3.1. Verify installation to be registered.
  id registerInstallationValidation = [OCMArg checkWithBlock:^BOOL(FIRInstallationsItem *obj) {
    [self assertValidCreatedInstallation:obj];
    XCTAssertEqual(obj.firebaseInstallationID.length, 22);
    return YES;
  }];

  // 3.2. Expect for `registerInstallation` to be called.
  FBLPromise<FIRInstallationsItem *> *registerPromise = [FBLPromise pendingPromise];
  OCMExpect([self.mockAPIService registerInstallation:registerInstallationValidation])
      .andReturn(registerPromise);

  // 4. Expect IIDStore to be checked for existing IID.
  FBLPromise *rejectedPromise = [FBLPromise pendingPromise];
  [rejectedPromise reject:[FIRInstallationsErrorUtil keychainErrorWithFunction:@"" status:-1]];
  OCMExpect([self.mockIIDStore existingIID]).andReturn(rejectedPromise);

  // 5. Call get installation and check.
  FBLPromise<FIRInstallationsItem *> *getInstallationPromise =
      [self.controller getInstallationItem];

  // 5.1. Wait for the stored item to be read and saved.
  OCMVerifyAllWithDelay(self.mockInstallationsStore, 0.5);

  // 5.2. Wait for `registerInstallation` to be called.
  OCMVerifyAllWithDelay(self.mockAPIService, 0.5);

  // 5.3. Expect for the registered installation to be saved.
  FIRInstallationsItem *registeredInstallation = [FIRInstallationsItem
      createRegisteredInstallationItemWithAppID:createdInstallation.appID
                                        appName:createdInstallation.firebaseAppName];

  OCMExpect([self.mockInstallationsStore
                saveInstallation:[OCMArg checkWithBlock:^BOOL(FIRInstallationsItem *obj) {
                  XCTAssertEqual(registeredInstallation, obj);
                  return YES;
                }]])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 5.5. Resolve `registerPromise` to simulate finished registration.
  [registerPromise fulfill:registeredInstallation];

  // 5.4. Wait for the task to complete.
  XCTAssert(FBLWaitForPromisesWithTimeout(0.5));

  XCTAssertNil(getInstallationPromise.error);
  // We expect the initially created installation to be returned - must not wait for registration to
  // complete here.
  XCTAssertEqual(getInstallationPromise.value, createdInstallation);

  // 5.5. Verify registered installation was saved.
  OCMVerifyAll(self.mockInstallationsStore);
  OCMVerifyAll(self.mockIIDStore);
}

- (void)testGetInstallationItem_WhenThereIsIIDAndNoFID_ThenIIDIsUsedAsFID {
  // 1. Stub store get installation.
  [self expectInstallationsStoreGetInstallationNotFound];

  // 2. Expect IIDStore to be checked for existing IID.
  NSString *existingIID = @"existing-iid";
  OCMExpect([self.mockIIDStore existingIID]).andReturn([FBLPromise resolvedWith:existingIID]);

  // 3. Stub store save installation.
  __block FIRInstallationsItem *createdInstallation;

  OCMExpect([self.mockInstallationsStore
                saveInstallation:[OCMArg checkWithBlock:^BOOL(FIRInstallationsItem *obj) {
                  [self assertValidCreatedInstallation:obj];
                  XCTAssertEqualObjects(existingIID, obj.firebaseInstallationID);
                  createdInstallation = obj;
                  return YES;
                }]])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 4. Stub API register installation.
  // 4.1. Verify installation to be registered.
  id registerInstallationValidation = [OCMArg checkWithBlock:^BOOL(FIRInstallationsItem *obj) {
    [self assertValidCreatedInstallation:obj];
    XCTAssertEqualObjects(existingIID, obj.firebaseInstallationID);
    return YES;
  }];

  // 4.2. Expect for `registerInstallation` to be called.
  FBLPromise<FIRInstallationsItem *> *registerPromise = [FBLPromise pendingPromise];
  OCMExpect([self.mockAPIService registerInstallation:registerInstallationValidation])
      .andReturn(registerPromise);

  // 5. Call get installation and check.
  FBLPromise<FIRInstallationsItem *> *getInstallationPromise =
      [self.controller getInstallationItem];

  // 5.1. Wait for the stored item to be read and saved.
  OCMVerifyAllWithDelay(self.mockInstallationsStore, 0.5);

  // 5.2. Wait for `registerInstallation` to be called.
  OCMVerifyAllWithDelay(self.mockAPIService, 0.5);

  // 5.3. Expect for the registered installation to be saved.
  FIRInstallationsItem *registeredInstallation = [FIRInstallationsItem
      createRegisteredInstallationItemWithAppID:createdInstallation.appID
                                        appName:createdInstallation.firebaseAppName];

  OCMExpect([self.mockInstallationsStore
                saveInstallation:[OCMArg checkWithBlock:^BOOL(FIRInstallationsItem *obj) {
                  XCTAssertEqual(registeredInstallation, obj);
                  return YES;
                }]])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 5.5. Resolve `registerPromise` to simulate finished registration.
  [registerPromise fulfill:registeredInstallation];

  // 5.4. Wait for the task to complete.
  XCTAssert(FBLWaitForPromisesWithTimeout(0.5));

  XCTAssertNil(getInstallationPromise.error);
  // We expect the initially created installation to be returned - must not wait for registration to
  // complete here.
  XCTAssertEqual(getInstallationPromise.value, createdInstallation);

  // 5.5. Verify registered installation was saved.
  OCMVerifyAll(self.mockInstallationsStore);
  OCMVerifyAll(self.mockIIDStore);
}

- (void)testGetInstallationItem_WhenCalledSeveralTimes_OnlyOneOperationIsPerformed {
  // 1. Expect the installation to be requested from the store only once.
  FIRInstallationsItem *storedInstallation1 =
      [FIRInstallationsItem createRegisteredInstallationItem];
  FBLPromise<FIRInstallationsItem *> *pendingStorePromise = [FBLPromise pendingPromise];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn(pendingStorePromise);

  // 3. Request installation n times
  NSInteger requestCount = 10;
  NSMutableArray *instllationPromises = [NSMutableArray arrayWithCapacity:requestCount];
  for (NSInteger i = 0; i < requestCount; i++) {
    [instllationPromises addObject:[self.controller getInstallationItem]];
  }

  // 4. Resolve store promise.
  [pendingStorePromise fulfill:storedInstallation1];

  // 5. Wait for operation to be completed and check.
  XCTAssert(FBLWaitForPromisesWithTimeout(0.5));

  for (FBLPromise<FIRInstallationsItem *> *installationPromise in instllationPromises) {
    XCTAssertNil(installationPromise.error);
    XCTAssertEqual(installationPromise.value, storedInstallation1);
  }

  OCMVerifyAll(self.mockInstallationsStore);

  // 6. Check that a new request is performed once prevoius finished.
  FIRInstallationsItem *storedInstallation2 =
      [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallation2]);

  FBLPromise<FIRInstallationsItem *> *installationPromise = [self.controller getInstallationItem];
  XCTAssert(FBLWaitForPromisesWithTimeout(0.5));

  XCTAssertNil(installationPromise.error);
  XCTAssertEqual(installationPromise.value, storedInstallation2);

  OCMVerifyAll(self.mockInstallationsStore);
}

#pragma mark - Get Auth Token

- (void)testGetAuthToken_WhenValidInstallationExists_ThenItIsReturned {
  // 1. Expect installation to be requested from the store.
  FIRInstallationsItem *storedInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallation]);

  // 2. Request auth token.
  FBLPromise<FIRInstallationsItem *> *promise = [self.controller getAuthTokenForcingRefresh:NO];

  // 3. Wait for the promise to resolve.
  FBLWaitForPromisesWithTimeout(0.5);

  // 4. Check.
  OCMVerifyAll(self.mockInstallationsStore);

  XCTAssertNil(promise.error);
  XCTAssertNotNil(promise.value);

  XCTAssertEqualObjects(promise.value.authToken.token, storedInstallation.authToken.token);
  XCTAssertEqualObjects(promise.value.authToken.expirationDate,
                        storedInstallation.authToken.expirationDate);
}

- (void)testGetAuthToken_WhenValidInstallationWithExpiredTokenExists_ThenTokenRequested {
  // 1.1. Expect installation to be requested from the store.
  FIRInstallationsItem *storedInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  storedInstallation.authToken.expirationDate = [NSDate dateWithTimeIntervalSinceNow:60 * 60 - 1];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallation]);

  // 1.2. Expect API request.
  FIRInstallationsItem *responseInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  responseInstallation.authToken.token =
      [responseInstallation.authToken.token stringByAppendingString:@"_new"];
  OCMExpect([self.mockAPIService refreshAuthTokenForInstallation:storedInstallation])
      .andReturn([FBLPromise resolvedWith:responseInstallation]);

  // 2. Request auth token.
  FBLPromise<FIRInstallationsItem *> *promise = [self.controller getAuthTokenForcingRefresh:NO];

  // 3. Wait for the promise to resolve.
  FBLWaitForPromisesWithTimeout(0.5);

  // 4. Check.
  OCMVerifyAll(self.mockInstallationsStore);

  XCTAssertNil(promise.error);
  XCTAssertNotNil(promise.value);

  XCTAssertEqualObjects(promise.value.authToken.token, responseInstallation.authToken.token);
  XCTAssertEqualObjects(promise.value.authToken.expirationDate,
                        responseInstallation.authToken.expirationDate);
}

- (void)testGetAuthTokenForcingRefresh_WhenValidInstallationExists_ThenTokenRequested {
  // 1.1. Expect installation to be requested from the store.
  FIRInstallationsItem *storedInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallation]);

  // 1.2. Expect API request.
  FIRInstallationsItem *responseInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  responseInstallation.authToken.token =
      [responseInstallation.authToken.token stringByAppendingString:@"_new"];
  OCMExpect([self.mockAPIService refreshAuthTokenForInstallation:storedInstallation])
      .andReturn([FBLPromise resolvedWith:responseInstallation]);

  // 2. Request auth token.
  FBLPromise<FIRInstallationsItem *> *promise = [self.controller getAuthTokenForcingRefresh:YES];

  // 3. Wait for the promise to resolve.
  FBLWaitForPromisesWithTimeout(0.5);

  // 4. Check.
  OCMVerifyAll(self.mockInstallationsStore);

  XCTAssertNil(promise.error);
  XCTAssertNotNil(promise.value);

  XCTAssertEqualObjects(promise.value.authToken.token, responseInstallation.authToken.token);
  XCTAssertEqualObjects(promise.value.authToken.expirationDate,
                        responseInstallation.authToken.expirationDate);
}

// TODO: Add error tests.

- (void)testGetAuthToken_WhenCalledSeveralTimes_OnlyOneOperationIsPerformed {
  // 1. Expect installation to be requested from the store.
  FIRInstallationsItem *storedInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];

  FBLPromise *storagePendingPromise = [FBLPromise pendingPromise];
  // Expect the instalation to be requested only once.
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn(storagePendingPromise);

  // 2. Request auth token n times.
  NSInteger requestCount = 10;
  NSMutableArray *authTokenPromises = [NSMutableArray arrayWithCapacity:requestCount];
  for (NSInteger i = 0; i < requestCount; i++) {
    [authTokenPromises addObject:[self.controller getAuthTokenForcingRefresh:NO]];
  }

  // 3. Finish the storage request.
  [storagePendingPromise fulfill:storedInstallation];

  // 4. Wait for the promise to resolve.
  FBLWaitForPromisesWithTimeout(0.5);

  // 5. Check.
  OCMVerifyAll(self.mockInstallationsStore);

  for (FBLPromise<FIRInstallationsItem *> *authPromise in authTokenPromises) {
    XCTAssertNil(authPromise.error);
    XCTAssertNotNil(authPromise.value);

    XCTAssertEqualObjects(authPromise.value.authToken.token, storedInstallation.authToken.token);
    XCTAssertEqualObjects(authPromise.value.authToken.expirationDate,
                          storedInstallation.authToken.expirationDate);
  }
}

- (void)testGetAuthTokenForceRefresh_WhenCalledSeveralTimes_OnlyOneOperationIsPerformed {
  // 1.1. Expect installation to be requested from the store.
  FIRInstallationsItem *storedInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallation]);

  // 1.2. Expect API request.
  FIRInstallationsItem *responseInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  responseInstallation.authToken.token =
      [responseInstallation.authToken.token stringByAppendingString:@"_new"];
  FBLPromise *pendingAPIPromise = [FBLPromise pendingPromise];
  OCMExpect([self.mockAPIService refreshAuthTokenForInstallation:storedInstallation])
      .andReturn(pendingAPIPromise);

  // 2. Request auth token n times.
  NSInteger requestCount = 10;
  NSMutableArray *authTokenPromises = [NSMutableArray arrayWithCapacity:requestCount];
  for (NSInteger i = 0; i < requestCount; i++) {
    [authTokenPromises addObject:[self.controller getAuthTokenForcingRefresh:YES]];
  }

  // 3. Finish the API request.
  [pendingAPIPromise fulfill:responseInstallation];

  // 4. Wait for the promise to resolve.
  FBLWaitForPromisesWithTimeout(0.5);

  // 5. Check.
  OCMVerifyAll(self.mockInstallationsStore);

  for (FBLPromise<FIRInstallationsItem *> *authPromise in authTokenPromises) {
    XCTAssertNil(authPromise.error);
    XCTAssertNotNil(authPromise.value);

    XCTAssertEqualObjects(authPromise.value.authToken.token, responseInstallation.authToken.token);
    XCTAssertEqualObjects(authPromise.value.authToken.expirationDate,
                          responseInstallation.authToken.expirationDate);
  }
}

#pragma mark - FID Deletion

- (void)testDeleteRegisteredInstallation {
  // 1. Expect installation to be requested from the store.
  FIRInstallationsItem *installation = [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:installation.appID
                                                      appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:installation]);

  // 2. Expect API request to delete installation.
  OCMExpect([self.mockAPIService deleteInstallation:installation])
      .andReturn([FBLPromise resolvedWith:installation]);

  // 3. Expect the installation to be removed from the storage.
  OCMExpect([self.mockInstallationsStore removeInstallationForAppID:installation.appID
                                                            appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 4. Expect FIRInstallationIDDidChangeNotification to be sent.
  XCTestExpectation *notificationExpectation = [self installationIDDidChangeNotificationExpectation];

  // 5. Call delete installation.
  FBLPromise<NSNull *> *promise = [self.controller deleteInstallation];

  // 6. Wait for operations to complete and check.
  FBLWaitForPromisesWithTimeout(0.5);

  XCTAssertNil(promise.error);
  XCTAssertTrue(promise.isFulfilled);
  [self waitForExpectations:@[ notificationExpectation ] timeout:0.5];
}

- (void)testDeleteUnregisteredInstallation {
  // 1. Expect installation to be requested from the store.
  FIRInstallationsItem *installation = [FIRInstallationsItem createValidInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:installation.appID
                                                      appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:installation]);

  // 2. Don't expect API request to delete installation.
  OCMReject([self.mockAPIService deleteInstallation:[OCMArg any]]);

  // 3. Expect the installation to be removed from the storage.
  OCMExpect([self.mockInstallationsStore removeInstallationForAppID:installation.appID
                                                            appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 4. Expect FIRInstallationIDDidChangeNotification to be sent.
  XCTestExpectation *notificationExpectation = [self installationIDDidChangeNotificationExpectation];

  // 5. Call delete installation.
  FBLPromise<NSNull *> *promise = [self.controller deleteInstallation];

  // 6. Wait for operations to complete and check.
  FBLWaitForPromisesWithTimeout(0.5);

  XCTAssertNil(promise.error);
  XCTAssertTrue(promise.isFulfilled);
  [self waitForExpectations:@[ notificationExpectation ] timeout:0.5];
}

- (void)testDeleteRegisteredInstallation_WhenAPIRequestFails_ThenFailsAndInstallationIsNotRemoved {
  // 1. Expect installation to be requested from the store.
  FIRInstallationsItem *installation = [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:installation.appID
                                                      appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:installation]);

  // 2. Expect API request to delete installation.
  FBLPromise *rejectedAPIPromise = [FBLPromise pendingPromise];
  [rejectedAPIPromise reject:[FIRInstallationsErrorUtil APIErrorWithHTTPCode:500]];
  OCMExpect([self.mockAPIService deleteInstallation:installation]).andReturn(rejectedAPIPromise);

  // 3. Don't expect the installation to be removed from the storage.
  OCMReject([self.mockInstallationsStore removeInstallationForAppID:[OCMArg any]
                                                            appName:[OCMArg any]]);

  // 4. Don't expect FIRInstallationIDDidChangeNotification to be sent.
  XCTestExpectation *notificationExpectation = [self installationIDDidChangeNotificationExpectation];
  notificationExpectation.inverted = YES;

  // 5. Call delete installation.
  FBLPromise<NSNull *> *promise = [self.controller deleteInstallation];

  // 6. Wait for operations to complete and check.
  FBLWaitForPromisesWithTimeout(0.5);

  XCTAssertEqualObjects(promise.error, [FIRInstallationsErrorUtil APIErrorWithHTTPCode:500]);
  XCTAssertTrue(promise.isRejected);
  [self waitForExpectations:@[ notificationExpectation ] timeout:0.5];
}

- (void)testDeleteRegisteredInstallation_WhenAPIFailsWithNotFound_ThenInstallationIsRemoved {
  // 1. Expect installation to be requested from the store.
  FIRInstallationsItem *installation = [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:installation.appID
                                                      appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:installation]);

  // 2. Expect API request to delete installation.
  FBLPromise *rejectedAPIPromise = [FBLPromise pendingPromise];
  [rejectedAPIPromise reject:[FIRInstallationsErrorUtil APIErrorWithHTTPCode:404]];
  OCMExpect([self.mockAPIService deleteInstallation:installation]).andReturn(rejectedAPIPromise);

  // 3. Expect the installation to be removed from the storage.
  OCMExpect([self.mockInstallationsStore removeInstallationForAppID:installation.appID
                                                            appName:installation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 4. Expect FIRInstallationIDDidChangeNotification to be sent.
  XCTestExpectation *notificationExpectation = [self installationIDDidChangeNotificationExpectation];

  // 5. Call delete installation.
  FBLPromise<NSNull *> *promise = [self.controller deleteInstallation];

  // 6. Wait for operations to complete and check.
  FBLWaitForPromisesWithTimeout(0.5);

  XCTAssertNil(promise.error);
  XCTAssertTrue(promise.isFulfilled);
  [self waitForExpectations:@[ notificationExpectation ] timeout:0.5];
}

- (void)testDeleteInstallation_WhenThereIsOngoingAuthTokenRequest_ThenUsesItsResult {
  // 1. Stub mocks for auth token request.

  // 1.1. Expect installation to be requested from the store.
  FIRInstallationsItem *storedInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn([FBLPromise resolvedWith:storedInstallation]);

  // 1.2. Expect API request.
  FIRInstallationsItem *responseInstallation =
      [FIRInstallationsItem createRegisteredInstallationItem];
  responseInstallation.authToken.token =
      [responseInstallation.authToken.token stringByAppendingString:@"_new"];
  FBLPromise *pendingAuthTokenAPIPromise = [FBLPromise pendingPromise];
  OCMExpect([self.mockAPIService refreshAuthTokenForInstallation:storedInstallation])
      .andReturn(pendingAuthTokenAPIPromise);

  // 2. Send auth token request.
  [self.controller getAuthTokenForcingRefresh:YES];

  OCMVerifyAllWithDelay(self.mockInstallationsStore, 0.5);
  OCMVerifyAllWithDelay(self.mockAPIService, 0.5);

  // 3. Delete installation.

  // 3.1. Don't expect installation to be requested from the store.
  OCMReject([self.mockInstallationsStore installationForAppID:[OCMArg any] appName:[OCMArg any]]);

  // 3.2. Expect API request to delete the UPDATED installation.
  OCMExpect([self.mockAPIService deleteInstallation:responseInstallation])
      .andReturn([FBLPromise resolvedWith:responseInstallation]);

  // 3.3. Expect the UPDATED installation to be removed from the storage.
  OCMExpect([self.mockInstallationsStore
                removeInstallationForAppID:responseInstallation.appID
                                   appName:responseInstallation.firebaseAppName])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 3.4. Call delete installation.
  FBLPromise<NSNull *> *deletePromise = [self.controller deleteInstallation];

  // 4. Fulfill auth token promise to proceed.
  [pendingAuthTokenAPIPromise fulfill:responseInstallation];

  // 5. Wait for operations to complete and check the result.
  FBLWaitForPromisesWithTimeout(0.5);

  XCTAssertNil(deletePromise.error);
  XCTAssertTrue(deletePromise.isFulfilled);
}

// TODO: Test a single delete installation request at a time.

#pragma mark - Notifications

- (void)testFIDDidChangeNotificationIsSentWhenFIDCreated {
  // 1. Stub - no installation.
  // 1.2. FID store.
  [self expectInstallationsStoreGetInstallationNotFound];

  OCMStub([self.mockInstallationsStore saveInstallation:[OCMArg any]])
      .andReturn([FBLPromise resolvedWith:[NSNull null]]);

  // 1.3. IID store.
  FBLPromise *rejectedPromise = [FBLPromise pendingPromise];
  [rejectedPromise reject:[FIRInstallationsErrorUtil keychainErrorWithFunction:@"" status:-1]];
  OCMExpect([self.mockIIDStore existingIID]).andReturn(rejectedPromise);

  // 1.4. API Service.
  OCMExpect([self.mockAPIService registerInstallation:[OCMArg any]])
      .andReturn([FBLPromise resolvedWith:[FIRInstallationsItem createRegisteredInstallationItem]]);

  // 2. Expect FIRInstallationIDDidChangeNotification to be sent.
  XCTestExpectation *notificationExpectation = [self installationIDDidChangeNotificationExpectation];

  // 3. Request FID.
  FBLPromise *promise = [self.controller getInstallationItem];
  FBLWaitForPromisesWithTimeout(0.5);

  // 4. Check.
  XCTAssertNil(promise.error);
  XCTAssertNotNil(promise.value);
  [self waitForExpectations:@[ notificationExpectation ] timeout:0.5];

  OCMVerifyAll(self.mockInstallationsStore);
  OCMVerifyAll(self.mockIIDStore);
  OCMVerifyAll(self.mockAPIService);
}

- (void)testFIDDidChangeNotificationIsSentWhenInstallationIsDeleted {
  
}

#pragma mark - Helpers

- (void)expectInstallationsStoreGetInstallationNotFound {
  NSError *notFoundError =
      [FIRInstallationsErrorUtil installationItemNotFoundForAppID:self.appID appName:self.appName];
  FBLPromise *installationNotFoundPromise = [FBLPromise pendingPromise];
  [installationNotFoundPromise reject:notFoundError];

  OCMExpect([self.mockInstallationsStore installationForAppID:self.appID appName:self.appName])
      .andReturn(installationNotFoundPromise);
}

- (void)assertValidCreatedInstallation:(FIRInstallationsItem *)installation {
  XCTAssertEqualObjects([installation class], [FIRInstallationsItem class]);
  XCTAssertEqualObjects(installation.appID, self.appID);
  XCTAssertEqualObjects(installation.firebaseAppName, self.appName);
  XCTAssertEqual(installation.registrationStatus, FIRInstallationStatusUnregistered);
  XCTAssertNotNil(installation.firebaseInstallationID);
}

- (XCTestExpectation *)installationIDDidChangeNotificationExpectation {
  XCTestExpectation *notificationExpectation =
  [self expectationForNotification:FIRInstallationIDDidChangeNotification
                            object:nil
                           handler:^BOOL(NSNotification *_Nonnull notification) {
                             return YES;
                           }];
  return notificationExpectation;
}

@end
