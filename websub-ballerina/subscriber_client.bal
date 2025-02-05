// Copyright (c) 2019 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/url;
import ballerina/http;
import ballerina/log;
import ballerina/mime;

# The HTTP based client for WebSub subscription and unsubscription.
public client class SubscriptionClient {

    private string url;
    private http:Client httpClient;
    private http:FollowRedirects? followRedirects = ();

    # Initializes the `websub:SubscriptionClient`.
    #
    # + url    - The URL at which the subscription should be changed
    # + config - The `http:ClientConfiguration` for the underlying client or `()`
    public isolated function init(string url, *http:ClientConfiguration config) returns error? {
        self.url = url;
        self.httpClient = check new (self.url, config);
        self.followRedirects = config?.followRedirects;
    }

    # Sends a subscription request to a WebSub Hub.
    # ```ballerina
    # websub:SubscriptionChangeResponse|error response = websubHubClientEP->subscribe(subscriptionRequest);
    # ```
    #
    # + subscriptionRequest - The `SubscriptionChangeRequest` containing the subscription details
    # + return - The `SubscriptionChangeResponse` indicating subscription details if the request was successful
    #           or else an `error` if an error occurred with the subscription request
    isolated remote function subscribe(SubscriptionChangeRequest subscriptionRequest)
        returns @tainted SubscriptionChangeResponse|error {

        http:Client httpClient = self.httpClient;
        http:Request builtSubscriptionRequest = buildSubscriptionChangeRequest(MODE_SUBSCRIBE, subscriptionRequest);
        var response = httpClient->post("", builtSubscriptionRequest);
        int redirectCount = getRedirectionMaxCount(self.followRedirects);
        return processHubResponse(self.url, MODE_SUBSCRIBE, subscriptionRequest, response, httpClient,
                                  redirectCount);
    }

    # Sends an unsubscription request to a WebSub Hub.
    # ```ballerina
    # websub:SubscriptionChangeResponse|error response = websubHubClientEP->unsubscribe(subscriptionRequest);
    # ```
    # + unsubscriptionRequest - The `SubscriptionChangeRequest` containing unsubscription details
    # + return - An unsubscription details if the request was successful or else an `error` if an error occurred
    #            with the unsubscription request
    isolated remote function unsubscribe(SubscriptionChangeRequest unsubscriptionRequest)
        returns @tainted SubscriptionChangeResponse|error {

        http:Client httpClient = self.httpClient;
        http:Request builtUnsubscriptionRequest = buildSubscriptionChangeRequest(MODE_UNSUBSCRIBE, unsubscriptionRequest);
        var response = httpClient->post("", builtUnsubscriptionRequest);
        int redirectCount = getRedirectionMaxCount(self.followRedirects);
        return processHubResponse(self.url, MODE_UNSUBSCRIBE, unsubscriptionRequest, response, httpClient,
                                  redirectCount);
    }

}

# Function to build the subscription request to subscribe at the hub.
#
# + mode - Whether the request is to subscribe or unsubscribe
# + subscriptionChangeRequest - The SubscriptionChangeRequest specifying the topic to subscribe and the
#                               parameters to use
# + return - An `http:Request` to be sent to the hub to subscribe/unsubscribe
isolated function buildSubscriptionChangeRequest(@untainted string mode, 
                                                 SubscriptionChangeRequest subscriptionChangeRequest) 
                                                returns (http:Request) {
    http:Request request = new;

    string callback = subscriptionChangeRequest.callback;
    var encodedCallback = url:encode(callback, "UTF-8");
    if (encodedCallback is string) {
        callback = encodedCallback;
    }

    string body = HUB_MODE + "=" + mode
        + "&" + HUB_TOPIC + "=" + subscriptionChangeRequest.topic
        + "&" + HUB_CALLBACK + "=" + callback;
    if (mode == MODE_SUBSCRIBE) {
        if (subscriptionChangeRequest.secret.trim() != "") {
            body = body + "&" + HUB_SECRET + "=" + subscriptionChangeRequest.secret;
        }
        if (subscriptionChangeRequest.leaseSeconds != 0) {
            body = body + "&" + HUB_LEASE_SECONDS + "=" + subscriptionChangeRequest.leaseSeconds.toString();
        }
    }
    request.setTextPayload(body);
    request.setHeader(CONTENT_TYPE, mime:APPLICATION_FORM_URLENCODED);
    return request;
}

# Function to process the response from the hub on subscription/unsubscription and extract required information.
#
# + hub - The hub to which the subscription/unsubscription request was sent
# + mode - Whether the request was sent for subscription or unsubscription
# + subscriptionChangeRequest - The sent subscription change request
# + response - The `http:Response` or an error received upon sending a request to the hub
# + httpClient - The underlying HTTP Client Endpoint
# + remainingRedirects - available redirects for the current subscription
# + return - The subscription/unsubscription details if the request was successful or else an `error`
#            if an error occurred
isolated function processHubResponse(@untainted string hub, @untainted string mode, 
                                     SubscriptionChangeRequest subscriptionChangeRequest,
                                     http:Response|http:PayloadType|error response, http:Client httpClient, 
                                     int remainingRedirects) returns @tainted SubscriptionChangeResponse|error {

    string topic = subscriptionChangeRequest.topic;
    if (response is error) {
        return error SubscriptionInitiationFailedError("Error occurred for request: Mode[" + mode+ "] at Hub[" + hub + "] - " + response.message());
    } else {
        http:Response hubResponse = <http:Response> response;
        int responseStatusCode = hubResponse.statusCode;
        if (responseStatusCode == http:STATUS_TEMPORARY_REDIRECT
                || responseStatusCode == http:STATUS_PERMANENT_REDIRECT) {
            if (remainingRedirects > 0) {
                string redirected_hub = check hubResponse.getHeader("Location");
                return invokeClientConnectorOnRedirection(redirected_hub, mode, subscriptionChangeRequest,
                                                            httpClient.config.auth, remainingRedirects - 1);
            }
            return error SubscriptionInitiationFailedError("Redirection response received for subscription change request made with " +
                               "followRedirects disabled or after maxCount exceeded: Hub [" + hub + "], Topic [" +
                               subscriptionChangeRequest.topic + "]");
        } else if (!isSuccessStatusCode(responseStatusCode)) {
            var responsePayload = hubResponse.getTextPayload();
            string errorMessage = "Error in request: Mode[" + mode + "] at Hub[" + hub + "]";
            if (responsePayload is string) {
                errorMessage = errorMessage + " - " + responsePayload;
            } else {
                errorMessage = errorMessage + " - Error occurred identifying cause: " + responsePayload.message();
            }
            return error SubscriptionInitiationFailedError(errorMessage);
        } else {
            if (responseStatusCode != http:STATUS_ACCEPTED) {
                log:printWarn(string`Subscription request considered successful for non 202 status code: ${responseStatusCode.toString()}`);
            }
            SubscriptionChangeResponse subscriptionChangeResponse = {hub:hub, topic:topic, response:hubResponse};
            return subscriptionChangeResponse;
        }
    }
}

# Invokes the `WebSubSubscriberConnector`'s remote functions for subscription/unsubscription on redirection from the
# original hub.
#
# + hub - The hub to which the subscription/unsubscription request is to be sent
# + mode - Whether the request is for subscription or unsubscription
# + subscriptionChangeRequest - The request containing the subscription/unsubscription details
# + auth - The auth config to use at the hub (if specified)
# + remainingRedirects - available redirects for the current subscription
# + return - The subscription/unsubscription details if the request was successful or else an `error`
#            if an error occurred
isolated function invokeClientConnectorOnRedirection(@untainted string hub, @untainted string mode, 
                                                     SubscriptionChangeRequest subscriptionChangeRequest, 
                                                     http:ClientAuthConfig? auth, int remainingRedirects)
    returns @tainted SubscriptionChangeResponse|error {

    if (mode == MODE_SUBSCRIBE) {
        return subscribeWithRetries(hub, subscriptionChangeRequest, auth, remainingRedirects = remainingRedirects);
    }
    return unsubscribeWithRetries(hub, subscriptionChangeRequest, auth, remainingRedirects = remainingRedirects);
}

isolated function subscribeWithRetries(string url, SubscriptionChangeRequest subscriptionRequest,
                              http:ClientAuthConfig? auth, int remainingRedirects = 0)
             returns @tainted SubscriptionChangeResponse| error {
    http:Client clientEndpoint = check new http:Client(url, { auth: auth });
    http:Request builtSubscriptionRequest = buildSubscriptionChangeRequest(MODE_SUBSCRIBE, subscriptionRequest);
    var response = clientEndpoint->post("", builtSubscriptionRequest);
    return processHubResponse(url, MODE_SUBSCRIBE, subscriptionRequest, response, clientEndpoint,
                              remainingRedirects);
}

isolated function unsubscribeWithRetries(string url, SubscriptionChangeRequest unsubscriptionRequest,
                                http:ClientAuthConfig? auth, int remainingRedirects = 0)
             returns @tainted SubscriptionChangeResponse|error {
    http:Client clientEndpoint = check new http:Client(url, {
        auth: auth
    });
    http:Request builtSubscriptionRequest = buildSubscriptionChangeRequest(MODE_UNSUBSCRIBE, unsubscriptionRequest);
    var response = clientEndpoint->post("", builtSubscriptionRequest);
    return processHubResponse(url, MODE_UNSUBSCRIBE, unsubscriptionRequest, response, clientEndpoint,
                              remainingRedirects);
}

isolated function getRedirectionMaxCount(http:FollowRedirects? followRedirects) returns int {
    if (followRedirects is http:FollowRedirects) {
        if (followRedirects.enabled) {
            return followRedirects.maxCount;
        }
    }
    return 0;
}
