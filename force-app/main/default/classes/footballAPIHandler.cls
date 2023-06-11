public with sharing class footballAPIHandler implements Schedulable {
  //The handleCallouts method is in charge of all the callouts. We call it from a (nested) schedulable job
  public void execute(SchedulableContext SC) {
    //We don't want the callouts to be launched after the end of the match. At my time zone, the match will finish at around 11PM
    if (Datetime.now().hour() < 23) {
      //We call the API
      handleCallouts();
      //We prepare a crontrigger to launch a new job, which will launch a new job 3 minutes later, which will launch a new job 3 minutes later...
      footballAPIHandler footballAPIJob = new footballAPIHandler();
      Datetime dt = datetime.now().addMinutes(3);
      String month = String.valueOf(dt.month());
      String day = String.valueOf(dt.day());
      String hour = String.valueOf(dt.hour());
      String minutes = String.valueOf(dt.minute());
      String cronStr =
        '0 ' +
        minutes +
        ' ' +
        hour +
        ' ' +
        day +
        ' ' +
        month +
        ' ?';
      System.schedule(
        'Nested job' +
        '-' +
        System.currentTimeMillis(),
        cronStr,
        footballAPIJob
      );
    }
  }
  public void finish(Database.BatchableContext BC) {
    //Our first job has to be launched ONCE only today, not tomorrow. So we cancel it on the finish method.
    AsyncApexJob a = [
      SELECT Id, Status, NumberOfErrors, JobItemsProcessed, TotalJobItems
      FROM AsyncApexJob
      WHERE Id = :BC.getJobId()
    ];
    system.abortJob(a.id);
  }
  //We make a callout from a schedulable Apex, so we need to add a @future(callout=true)
  @future(callout=true)
  public static void handleCallouts() {
    //We get the credential from a custom metadata type record we saved
    String key = String.valueOf(
      API_Credentials__mdt.getInstance('Football_API').get('Token__c')
    );
    Http http = new Http();
    HttpRequest request = new HttpRequest();

    //These parameters are defined on the API doc
    request.setHeader('X-Rapidapi-Key', key);
    request.setHeader('X-Rapidapi-Host', 'api-football-beta.p.rapidapi.com');

    //We use a GET method to get the match informations
    request.setMethod('GET');
    //We verify if we already have a record called 'Manchester City UCL Final'. We've created it on our first callout
    List<Match__c> matchList = [
      SELECT Id, score__c, API_Id__c, numberOfGoals__c
      FROM Match__c
      WHERE name = 'Manchester City UCL Final'
    ];
    //If we don't, we use the live=all parameter on our endpoint, end then, we send our request
    if (matchList.size() == 0) {
      request.setEndpoint(
        'https://api-football-beta.p.rapidapi.com/fixtures?live=all'
      );
      HttpResponse httpresponse = http.send(request);
      //if the request has succeeded, we handle this callout on the firstCallout method
      if (httpresponse.getStatusCode() == 200) {
        firstCallout(httpresponse.getBody());
      }
    //if we do, we can call the API with the fixture ID, that we stored on the Match__c record
    } else {
      request.setEndpoint(
        'https://api-football-beta.p.rapidapi.com/fixtures/events?fixture=' +
        String.valueOf(matchList[0].API_Id__c)
      );
      HttpResponse httpresponse = http.send(request);
      //if the request has succeeded, we call the otherCallouts() method
      if (httpresponse.getStatusCode() == 200) {
        otherCallouts(matchList[0], httpresponse.getBody());
      }
    }
  }
  //The only job of this method is to create a Match__c record for the current match, with the data we get from the API
  public static void firstCallout(String jsonResponse) {
    //We transform our String response to a map
    Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(
      jsonResponse
    );
    List<Object> responseList = (List<Object>) (responseMap.get('response'));
    List<Match__c> matchToQuery = new List<Match__c>();
    //We get multiple matches, so multiple responses
    for (Object eachResponse : responseList) {
      Map<String, Object> teamsMap = (Map<String, Object>) eachResponse;
      //We verify for each team if its name contains 'manchester'
      Map<String, Object> teams = (Map<String, Object>) teamsMap.get('teams');
      for (String eachTeam : teams.keySet()) {
        Map<String, Object> mappedTeam = (Map<String, Object>) teams.get(
          eachTeam
        );
        if (
          String.valueOf(mappedTeam.get('name'))
            .toLowerCase()
            .contains('manchester')
        ) {
          //if yes, we get its fixture id, and save it to a new Match__c record, called 'Manchester City UCL Final'
          Object fixtureObj = ((Map<String, Object>) eachResponse)
            .get('fixture');
          Map<String, Object> fixtureObjMap = (Map<String, Object>) fixtureObj;
          String fixtureId = String.valueOf(fixtureObjMap.get('id'));
          matchToQuery.add(
            new Match__c(
              name = 'Manchester City UCL Final',
              API_Id__c = fixtureId,
              score__c = '0-0',
              numberOfGoals__c = 0
            )
          );
        }
      }
    }
    //We insert the record
    insert matchToQuery;
  }
  //We give to this method the actual match record, and the body from the response of the callout
  public static void otherCallouts(Match__c match, String jsonResponse) {
    //To work with it, I used to save the JSON inside a record, to avoid using too much the API
    // Saved_Json__c s = new Saved_Json__c(JSON__c = jsonResponse, name = 'final');
    // insert s;

    //We transform the response body to a map
    Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(
      jsonResponse
    );
    //There is one match, so one response here
    List<Object> responseList = (List<Object>) (responseMap.get('response'));

    //This was the previous version. We got the "away goals" and "home goals" directly from the API
    //And we used to put them inside a text field, but it didn't work during the final
    //Map<String, Object> firstRes = (Map<String, Object>) responseList[0];
    // Map<String, Object> goals = (Map<String, Object>) firstRes.get('goals');
    // String currentResult =
    //   String.valueOf(goals.get('home')) +
    //   '-' +
    //   String.valueOf(goals.get('away'));

    //Instead now, we count the total number of goals during the match
    //String scorerForNotification = '';
    Integer numberOfGoals = 0;

    //We don't have a node called 'events' now. We just have a normal list
    // List<Object> events = (List<Object>) firstRes.get('events');

    //For each event, we verify if a goal has been scored. If yes, we get the scorer name, the time, and the team.
    //And also, we count the total number of goals by incrementing the variable numberOfGoals.
    for (Object eachEvent : responseList) {
      Map<String, Object> mappedEvent = (Map<String, Object>) eachEvent;
      if (mappedEvent.get('type') == 'Goal') {
        Map<String, Object> scorer = (Map<String, Object>) mappedEvent.get(
          'player'
        );
        Map<String, Object> scorerTime = (Map<String, Object>) mappedEvent.get(
          'time'
        );
        Map<String, Object> scorerTeam = (Map<String, Object>) mappedEvent.get(
          'team'
        );
        String scorerNameValue = String.valueOf(scorer.get('name'));
        String scorerTimeValue = String.valueOf(scorerTime.get('elapsed'));
        String scorerTeamValue = String.valueOf(scorerTeam.get('name'));
        //We increment the scorerForNotification variable, in order to(maybe) display it on the screen
        scorerForNotification +=
          scorerNameValue +
          ', ' +
          scorerTimeValue +
          ' for  ' +
          scorerTeamValue +
          '...';
        numberOfGoals += 1;
      }
    }
    //if the numberOfGoals variable equals the field value, we stop the algorithm
    if (numberOfGoals == match.numberOfGoals__c) {
      return;
    }
    //if there is a change(ie: previously it was 0-0 on the record, and now it's 1-0), we update the record, and send the notification
    update new Match__c(Id = match.Id, numberOfGoals__c = numberOfGoals);
    sendGoalNotification(scorerForNotification);
  }

  //Here I've reused the method I had used for the jokes getter development 
  public static void sendGoalNotification(String GoalEvent) {
    // We get the notification type Id
    CustomNotificationType notificationType = [
      SELECT Id, DeveloperName
      FROM CustomNotificationType
      WHERE DeveloperName = 'Football_Notification'
    ];

    // We a new custom notification
    Messaging.CustomNotification notification = new Messaging.CustomNotification();

    //We add the announcement
    notification.setTitle('GOAL GOAL GOAL GOAAAAAAAAAAL');
    notification.setBody(GoalEvent);

    // We set the notification type Id with the value we got from the previous SOQL
    notification.setNotificationTypeId(notificationType.Id);

    //I've defined the redirection link to a page that doesn't exist. But it could be anything
    notification.setTargetId('000000000000000');

    // When everything is set, I send the notification. If I cannot, I catch the error and display it on the debug logs
    try {
      notification.send(new Set<String>{ UserInfo.getUserId() });
    } catch (Exception e) {
      System.debug('Problem sending notification: ' + e.getMessage());
    }
  }
}
