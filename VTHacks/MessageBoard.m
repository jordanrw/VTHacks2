//
//  MessageBoard.m
//  VTHacks
//
//  Created by Carlos Second Admin on 3/2/14.
//  Copyright (c) 2014 Vincent Ngo. All rights reserved.
//

#import "MessageBoard.h"
#import "Constants.h"
#import <AWSRuntime/AWSRuntime.h>
#import "AppDelegate.h"
#import "AnnoucementViewController.h"
#import "Reachability.h"

@implementation MessageBoard


NSComparisonResult dateSort(NSDictionary *d1, NSDictionary *d2, void *context) {
    NSDate *date1 = d1[@"date"];
    NSDate *date2 = d2[@"date"];
    return [date2 compare:date1];
}

/* last stored completion handler from a server request */
static completionHandler serverResponseHandler;

/* ("awards", "contacts", "schedule", "credentials") */
static NSString *currentlyProcessing;

static MessageBoard *_instance = nil;

+(MessageBoard *)instance
{
    if (!_instance) {
        // check if previous keys exist or have expired
        @synchronized([MessageBoard class])
        {
            if (!_instance) {
                _instance = [self new];
            }
        }
    }
    
    return _instance;
}

-(void)getDataFromServer:(NSString*) type completionHandler:(completionHandler)handler
{

    if (!([type isEqualToString:@"awards"] || [type isEqualToString:@"schedule"] || [type isEqualToString:@"contacts"]))
        NSLog(@"Error: call from server must be for a type of awards, schedue, or contacts");

    currentlyProcessing = type;
    serverResponseHandler = [handler copy];
    
    NSString *urlAsString = [NSString stringWithFormat:@"http://vthacks-env-pmkrjpmqpu.elasticbeanstalk.com/get_%@", type];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlAsString]];
    NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:request delegate:self];
}


// If we stored credentials that are still good, set them and return success.
// If they dont exist or are expired, return false.
-(BOOL)previousCredentialsStillValid
{
    tempExpirationString = [[NSUserDefaults standardUserDefaults] objectForKey:@"LAST_EXPIRATION_STRING"];
    if (tempExpirationString)
    {
        NSDate *expirationDate = [MessageBoard convertStringToDate:tempExpirationString];
        BOOL isExpired = [MessageBoard isExpired:expirationDate];
        
        if (isExpired)
        {
            NSLog(@"PREVIOUS CREDENTIALS ARE NOT VALID. Will NEED TO RENEW");
            return NO;
        }
        else
            NSLog(@"Previous credentials are still valid!");
        
        // set all credentials and device endpoint
        tempSECRET_KEY = [[NSUserDefaults standardUserDefaults] objectForKey:@"LAST_SECRET_KEY"];
        tempACCESS_KEY_ID = [[NSUserDefaults standardUserDefaults] objectForKey:@"LAST_ACCESS_KEY_ID"];
        tempSECURITY_TOKEN = [[NSUserDefaults standardUserDefaults] objectForKey:@"LAST_SECURITY_TOKEN"];
        endpointARN = [[NSUserDefaults standardUserDefaults] objectForKey:@"DEVICE_ENDPOINT"];

        // set everything up using these previous credentials but dont do a full run
        [self runSetupWithCredentials:NO];


        return YES;
    }
    else
    {
        NSLog(@"PREVIOUS CREDENTIALS ARE NOT VALID. Will NEED TO RENEW");
        return NO;
    }
}


// called when there is not instance of the messageboard singleton
// should display splash screen here while there is still data to be fetched
-(id)init
{
    
    Reachability *networkReachability = [Reachability reachabilityForInternetConnection];
    NetworkStatus networkStatus = [networkReachability currentReachabilityStatus];
    if (networkStatus == NotReachable) {
        NSLog(@"There IS NO internet connection");
        return nil;
    }
    self = [super init];

    // this call will restore everything if it finds valid credentials stored in defaults - returns true in that case
    // else it will return false
    if ([self previousCredentialsStillValid])
        return self;
    
    currentlyProcessing = @"credentials";
    NSString *urlAsString = @"http://vthacks-env-pmkrjpmqpu.elasticbeanstalk.com/get_credentials";
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlAsString]];
    // Create url connection and fire request
    NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    return self;
}


/* Sets up all the clients and aws services once we have access to temp credentials from server 
   @param fullRun - only do a full run of this method if credentials have expired.
                    a full run of this set's up all the services from scratch again
 */
-(void) runSetupWithCredentials:(BOOL)fullRun
{
    didSetupCorrectly = YES;
    NSString *logStr = fullRun? @" fullRun is TRUE." : @" fullRun is FALSE";
    NSLog(@"-------- doing runSetupWithCredentials %@-----", logStr);
    if (self != nil)
    {
        // Create credentials from the temporary values returned by the tvm on the server
        credentials = [[AmazonCredentials alloc] initWithAccessKey:tempACCESS_KEY_ID
                                                 withSecretKey:tempSECRET_KEY withSecurityToken:tempSECURITY_TOKEN];

        // Init SNS and SQS clients
        snsClient = [[AmazonSNSClient alloc] initWithCredentials:credentials];
        sqsClient = [[AmazonSQSClient alloc] initWithCredentials:credentials];
        snsClient.endpoint = [AmazonEndpoints snsEndpoint:US_EAST_1];
        sqsClient.endpoint = [AmazonEndpoints sqsEndpoint:US_EAST_1];

        if (snsClient == nil || sqsClient == nil)
            NSLog(@"--------- ERROR: SNS or SQS client is nil !!!! --------- ");
        
        topicARN = TOPIC_ARN;
        queueUrl = QUEUE_URL;
        if (fullRun)
            [self subscribeQueue];
        
        // Find endpointARN for this device if there is one.
        if (fullRun)
        {
            endpointARN = [self findEndpointARN];
            if (endpointARN == nil)
            {
                NSLog(@"UNABLE TO findEnpointARN. Will try to create applicationEndPoint");
                [self createApplicationEndpoint];
            }
        }
        [self subscribeDevice:nil];
//        if()
//        {
            /* reload AnnouncementViewController table data with newly found messages */
//            AppDelegate * appDel = [[UIApplication sharedApplication] delegate];
//            AnnoucementViewController *annVC =  appDel.announceVC;
//            [annVC reloadAnnouncementsWithInstance:self];
//        }
//        else
//            didSetupCorrectly = NO;
    }

    NSLog(@"Done with runSetupWithCredentials. Here's endpoint ARN: %@", endpointARN);
    
}



- (void)subscribeDevice:(id)sender
{
    
#if TARGET_IPHONE_SIMULATOR
    [[Constants universalAlertsWithTitle:@"Unable to Subscribe Device" andMessage:@"Push notifications are not supported in the simulator."] show];
    return;
#endif
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        
//        dispatch_async(dispatch_get_main_queue(), ^{
//            
//            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
//        });
        BOOL didWork = [self subscribeDevice];
        if (didWork) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"Subscription worked!!!");
            });
        }
        else
            NSLog(@"SUBSCRIPTION DID NOT WORK");
        
//        dispatch_async(dispatch_get_main_queue(), ^{
//            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
//        });
    });
//    return didWork;
}

-(bool)createApplicationEndpoint
{
    
    NSString *deviceToken = [[NSUserDefaults standardUserDefaults] stringForKey:@"myDeviceToken"];
    if (!deviceToken) {
        [[Constants universalAlertsWithTitle:@"deviceToken not found!" andMessage:@"Device may fail to register with Apple's Notification Service, please check debug window for details"] show];
        return NO;
    }
    
    SNSCreatePlatformEndpointRequest *endpointReq = [[SNSCreatePlatformEndpointRequest alloc] init];
    endpointReq.platformApplicationArn = PLATFORM_APPLICATION_ARN;
    endpointReq.token = deviceToken;
    @try
    {
        SNSCreatePlatformEndpointResponse *endpointResponse = [snsClient createPlatformEndpoint:endpointReq];
        if (endpointResponse.error != nil)
        {
            NSLog(@"Error: %@", endpointResponse.error);
            [[Constants universalAlertsWithTitle:@"CreateApplicationEndpoint Error" andMessage:endpointResponse.error.userInfo.description] show];
            return NO;
        }
        
        endpointARN = endpointResponse.endpointArn;
        [[NSUserDefaults standardUserDefaults] setObject:endpointResponse.endpointArn forKey:@"DEVICE_ENDPOINT"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    @catch (NSException* ex)
    {
        NSLog(@"Here is the aws exception %@", [ex description]);
    }
    return YES;
}

-(bool)subscribeDevice
{
    NSError *localError = nil;
    bool didWork = [self subscribeDeviceWithError:localError];
    if (!didWork && localError && [localError code] == 1009)
    {
        [[Constants universalAlertsWithTitle:@"Offline Error" andMessage:@"No Internet Connection! Please connect in order to load the data."] show];
        return NO;
    }

    return didWork;
}


-(bool)subscribeDeviceWithError:(NSError*)error
{
    if (endpointARN == nil)
    {
        NSLog(@"Sorry, will be unable to subscribe this device to the topic because we dont have an endpointARN yet :( ");
        return NO;
    }
    
    @try
    {
        SNSSubscribeRequest *sr = [[SNSSubscribeRequest alloc] initWithTopicArn:topicARN andProtocol:@"application" andEndpoint:endpointARN];
        SNSSubscribeResponse *subscribeResponse = [snsClient subscribe:sr];
        if(subscribeResponse.error != nil)
        {
            NSLog(@"Error: %@ and %@", subscribeResponse.error, subscribeResponse.error.userInfo.description);
            return NO;
        }
        else
            NSLog(@"IT WORKED. THIS APP IS SUBSCRIBED TO the SNS TOPIC!");
    }
    @catch (NSException* ex)
    {
        if ([ex isKindOfClass:[AmazonServiceException class]] && [(AmazonServiceException*)ex statusCode] == 1009)
            error = [NSError errorWithDomain:@"NO INTERNET" code:1009 userInfo:@{NSLocalizedDescriptionKey:@"NO INTERNET ACCESS!"}];
        else if ([ex isKindOfClass:[AmazonClientException class]])
            error = [NSError errorWithDomain:@"NO INTERNET" code:1009 userInfo:@{NSLocalizedDescriptionKey:@"NO INTERNET ACCESS!"}];
        NSLog(@"Here is the aws exception %@", [ex description]);
        return NO;
    }
    return YES;
}


-(void)subscribeQueue
{
    NSString *queueArn = QUEUE_ARN;
    
    SNSSubscribeRequest *request = [[SNSSubscribeRequest alloc] initWithTopicArn:topicARN andProtocol:@"sqs" andEndpoint:queueArn];
    SNSSubscribeResponse *subscribeResponse = [snsClient subscribe:request];
    if(subscribeResponse.error != nil)
    {
        NSLog(@"Error: %@", subscribeResponse.error);
    }
}



-(NSMutableArray *)listSubscribers
{
    SNSListSubscriptionsByTopicRequest  *ls       = [[SNSListSubscriptionsByTopicRequest alloc] initWithTopicArn:topicARN];
    SNSListSubscriptionsByTopicResponse *response = [snsClient listSubscriptionsByTopic:ls];
    if(response.error != nil)
    {
        NSLog(@"Error: %@", response.error);
        return [NSMutableArray array];
    }
    
    return response.subscriptions;
}




-(void)updateCacheWithAnnouncement:(NSDictionary *)announcement
{
    if (cachedAnnouncements != nil) {
        [cachedAnnouncements insertObject:announcement atIndex:0];
    }
}

-(void)getAnnouncements:(jsonListCallback)handler usingPullToRefresh:(BOOL)skipCache
{
    // only return cached response if its available
    if (!skipCache && cachedAnnouncements)
    {
        handler(cachedAnnouncements, nil);
        return;
    }
    
    __block NSMutableArray *rawJSON = nil;
    
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
            NSError *localError = nil;

            rawJSON = [self getMessagesFromQueueWithError:localError];
            if (localError != nil) {
                [[Constants universalAlertsWithTitle:@"Offline Error" andMessage:@"No Internet Connection! Please connect in order to load the data."] show];
                handler(nil,localError);
                return;
            }
            localError = nil;
            if (!rawJSON || [rawJSON count] == 0)
            {
                localError = [NSError errorWithDomain:@"test" code:200 userInfo:@{NSLocalizedDescriptionKey:@"Sorry, NO MESSAGES FOUND IN QUEUE."}];
                handler(nil, localError);
            }
            else
            {
                NSMutableArray *multipleJsons = [[NSMutableArray alloc] initWithCapacity:[rawJSON count]];
                // keeps track of messages
                NSMutableDictionary *tempMessageHistory = [[NSMutableDictionary alloc] initWithCapacity:[rawJSON count]];
                for (SQSMessage *rawMessage in rawJSON)
                {
                    NSString *body = [rawMessage body];
                    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:&localError];
                    
                    // get the date from time-stamp (initially comes in as utc timezone)
                    NSDate *utcDate = [NSDate dateWithISO8061Format:jsonDict[@"Timestamp"]];
                    NSString *localDateString = [NSDateFormatter localizedStringFromDate:utcDate dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterMediumStyle];
                    NSString * message = jsonDict[@"Message"];
                    if (!tempMessageHistory[message]) //dont allow repeats
                    {
                        NSArray *components = [message componentsSeparatedByString:@"|"];
                        if ([components count] == 2)
                        {
                            NSString *simpleTimeString = [MessageBoard getSimpleTimeFromDateString:localDateString];
                            NSDictionary *simpleDictionary = @{@"title" : components[0], @"body" : components[1], @"date":utcDate, @"dateString":localDateString, @"simpleTimeString":simpleTimeString};
                            [multipleJsons addObject:simpleDictionary];
                        }
                        else if (message && [message length] > 0)
                        {
                            NSString *simpleTimeString = [MessageBoard getSimpleTimeFromDateString:localDateString];
                            NSDictionary *simpleDictionary = @{@"title" : @"Announcement", @"body" : message, @"date":utcDate, @"dateString":localDateString, @"simpleTimeString":simpleTimeString};
                            [multipleJsons addObject:simpleDictionary];
                        }
                        else
                            NSLog(@"Found a strange message, it didnt use the | seperator. Here it is: %@", message);
                    }
                    else
                        NSLog(@"Reading of Queue found a duplicate message. I will skip it. Here's the message: %@", message);
                    tempMessageHistory[message] = [NSNumber numberWithBool:YES];
                }

                // sort the array in descending order
                NSArray *sorted =[multipleJsons sortedArrayUsingFunction:dateSort context:nil];
                NSMutableArray *sortedAnnouncements = [NSMutableArray arrayWithArray:sorted];
                cachedAnnouncements = sortedAnnouncements;
                handler(sortedAnnouncements, localError);
            }


    });
    
    
}


+(NSString *)getSimpleTimeFromDateString:(NSString *)dateString
{
    NSArray *components = [dateString componentsSeparatedByString:@" "];
    if (components && [components count] == 5)
    {
        NSString *longTimeString = components[3];
        NSArray *timeComponents = [longTimeString componentsSeparatedByString:@":"];
        NSString *amOrPm = components[4];
    
        NSString *finalString = [NSString stringWithFormat:@"%@:%@ %@", timeComponents[0], timeComponents[1], amOrPm];
        return finalString;
    }
    else
        return @"";
    

    
}

-(NSMutableArray *)getMessagesFromQueueWithError:(NSError*)error
{
    SQSReceiveMessageRequest *rmr = [[SQSReceiveMessageRequest alloc] initWithQueueUrl:queueUrl];
    rmr.maxNumberOfMessages = [NSNumber numberWithInt:10];
    rmr.visibilityTimeout   = [NSNumber numberWithInt:10];
    
    
    SQSReceiveMessageResponse *response    = nil;
    NSMutableArray *allMessages = [NSMutableArray array];
    @try
    {
        do {
            response = [sqsClient receiveMessage:rmr];
            if(response.error != nil)
            {
                NSLog(@"Error: %@", response.error);
                return [NSMutableArray array];
            }
            
            [allMessages addObjectsFromArray:response.messages];
            [NSThread sleepForTimeInterval:0.2];
        } while ( [response.messages count] != 0);
    }
    @catch (NSException* ex)
    {
        if ([ex isKindOfClass:[AmazonServiceException class]] && [(AmazonServiceException*)ex statusCode] == 1009)
            error = [NSError errorWithDomain:@"NO INTERNET" code:1009 userInfo:@{NSLocalizedDescriptionKey:@"NO INTERNET ACCESS!"}];
        NSLog(@"Here is the aws exception %@", [ex description]);
    }
    
    return allMessages;
}

-(void)deleteMessageFromQueue:(SQSMessage *)message
{
    SQSDeleteMessageRequest *request = [[SQSDeleteMessageRequest alloc] initWithQueueUrl:queueUrl andReceiptHandle:message.receiptHandle];
    SQSDeleteMessageResponse *deleteMessageResponse = [sqsClient deleteMessage:request];
    if(deleteMessageResponse.error != nil)
    {
        NSLog(@"Error: %@", deleteMessageResponse.error);
    }
}

// Get the QueueArn attribute from the Queue.  The QueueArn is necessary for create a policy on the queue
// that allows for messages from the Amazon SNS Topic.
-(NSString *)getQueueArn:(NSString *)theQueueUrl
{
    SQSGetQueueAttributesRequest *gqar = [[SQSGetQueueAttributesRequest alloc] initWithQueueUrl:theQueueUrl];
    [gqar.attributeNames addObject:@"QueueArn"];
    
    SQSGetQueueAttributesResponse *response = [sqsClient getQueueAttributes:gqar];
    if(response.error != nil)
    {
        NSLog(@"Error: %@", response.error);
        return nil;
    }
    
    return [response.attributes valueForKey:@"QueueArn"];
}


-(NSString *)findEndpointARN
{
    if (endpointARN != nil)
        return endpointARN;
    else
    {
        NSString *storedEndpoint = [[NSUserDefaults standardUserDefaults] stringForKey:@"DEVICE_ENDPOINT"];
        return storedEndpoint;
    }
    
}

-(void)dealloc
{

}

#pragma mark NSURLConnection Delegate Methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    // A response has been received, this is where we initialize the instance var you created
    // so that we can append data to it in the didReceiveData method
    // Furthermore, this method is called each time there is a redirect so reinitializing it
    // also serves to clear it
    _responseData = [[NSMutableData alloc] init];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    // Append the new data to the instance variable you declared
    [_responseData appendData:data];
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse*)cachedResponse
{
    // Return nil to indicate not necessary to store a cached response for this connection
    return nil;
}



/*
    HERE IS WHERE WE STORE THE RESULT FROM THE SERVER CALL
 */
- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    // The request is complete and data has been received
    // You can parse the stuff in your instance variable now
    NSLog(@"Success! connection returned something. Time to parse JSON.");
    NSError *localError = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:_responseData options:0 error:&localError];
    
    
    if (!currentlyProcessing)
    {
        NSLog(@"Error: not set to currently process any server request - will not do anything with response");
        return;
    }
    else if (localError)
        return;
    
    /* If response correspond to temporary credential, store values and run the setup */
    if (currentlyProcessing && [currentlyProcessing isEqualToString:@"credentials"] && jsonDict)
    {
        NSLog(@"Here is the response JSON: %@", jsonDict);

        // Grab temporary credentials from the response JSON
        tempSECRET_KEY = jsonDict[@"secretAccessKey"];
        tempACCESS_KEY_ID = jsonDict[@"accessKeyID"];
        tempSECURITY_TOKEN = jsonDict[@"securityToken"];
        tempExpirationString = jsonDict[@"expiration"];
        [self runSetupWithCredentials:YES];

        // save temporary credentials
        [[NSUserDefaults standardUserDefaults] setObject:tempSECRET_KEY forKey:@"LAST_SECRET_KEY"];
        [[NSUserDefaults standardUserDefaults] setObject:tempACCESS_KEY_ID forKey:@"LAST_ACCESS_KEY_ID"];
        [[NSUserDefaults standardUserDefaults] setObject:tempSECURITY_TOKEN forKey:@"LAST_SECURITY_TOKEN"];
        [[NSUserDefaults standardUserDefaults] setObject:tempExpirationString forKey:@"LAST_EXPIRATION_STRING"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    else if ([currentlyProcessing isEqualToString:@"schedule"] || [currentlyProcessing isEqualToString:@"awards"] ||
             [currentlyProcessing isEqualToString:@"contacts"])
    {
        NSLog(@"Received a response from our server. Will call handler if one was set.");
        serverResponseHandler(jsonDict,localError);
        currentlyProcessing = @"";
    }
    else
        NSLog(@"Error: URLConnection response was not recognized or stored.");
    
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    // The request has failed for some reason!
    // Check the error var
    NSLog(@"The url connection failed. Here's the error: %@", [error description]);
}

#pragma mark DATE FUNCTIONS

+ (NSInteger)daysBetweenDate:(NSDate*)fromDateTime andDate:(NSDate*)toDateTime
{
    NSDate *fromDate;
    NSDate *toDate;
    
    NSCalendar *calendar = [NSCalendar currentCalendar];
    
    [calendar rangeOfUnit:NSDayCalendarUnit startDate:&fromDate
                 interval:NULL forDate:fromDateTime];
    [calendar rangeOfUnit:NSDayCalendarUnit startDate:&toDate
                 interval:NULL forDate:toDateTime];
    
    NSDateComponents *difference = [calendar components:NSDayCalendarUnit
                                               fromDate:fromDate toDate:toDate options:0];
    
    return [difference day];
}



// Returns a simple date object that only contains the year-month-day
+(NSDate *)convertStringToDate:(NSString *)expiration
{
    if (!expiration)
        return nil;

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd"];
    NSDate *resultDate = [dateFormatter dateFromString:[expiration substringToIndex:10]];
    return resultDate;
}

// In our case, we will say it's expired if current datetime is same month/day
+(bool)isExpired:(NSDate *)date
{
    NSDate *soon = [NSDate dateWithTimeIntervalSinceNow:(15 * 60)];  // Fifteen minutes from now.
    if ([MessageBoard daysBetweenDate:soon andDate:date] == 0 || [soon laterDate:date] == soon)
        return YES;
    else
        return NO;
}

-(bool)areCredentialsExpired
{
    NSString *expiration = tempExpirationString;
    NSDate *expirationDate = [MessageBoard convertStringToDate:expiration];
    //NSLog(@"Here is the current expiration date: %@", expirationDate);
    return [MessageBoard isExpired:expirationDate];

}

@end
