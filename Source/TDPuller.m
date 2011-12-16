//
//  TDPuller.m
//  TouchDB
//
//  Created by Jens Alfke on 12/2/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//

#import "TDPuller.h"
#import "TDDatabase.h"
#import "TDRevision.h"
#import "TDChangeTracker.h"
#import "TDBatcher.h"
#import "TDInternal.h"



@interface TDPuller () <TDChangeTrackerClient>
- (void) pullRemoteRevision: (TDRevision*)rev;
- (void) insertRevisions: (NSArray*)revs;
@end


@implementation TDPuller


- (void)dealloc {
    [_changeTracker stop];
    [_changeTracker release];
    [_revsToInsert release];
    [super dealloc];
}


- (void) start {
    if (_running)
        return;
    Assert(!_changeTracker);
    [super start];
    LogTo(Sync, @"*** STARTING PULLER to <%@> from #%@", _remote, _lastSequence);
    
    if (!_revsToInsert) {
        _revsToInsert = [[TDBatcher alloc] initWithCapacity: 100 delay: 0.25
                                                  processor: ^(NSArray *revs) {
                                                      [self insertRevisions: revs];
                                                  }];
    }
    
    _thread = [NSThread currentThread];
    _changeTracker = [[TDChangeTracker alloc]
                                   initWithDatabaseURL: _remote
                                                  mode: (_continuous ? kLongPoll :kOneShot)
                                          lastSequence: [_lastSequence intValue]
                                                client: self];
    [_changeTracker start];
    // TODO: In non-continuous mode, only get the existing changes; don't listen for new ones
}


- (void) stop {
    _changeTracker.client = nil;  // stop it from calling my -changeTrackerStopped
    [_changeTracker stop];
    [_changeTracker release];
    _changeTracker = nil;
    [super stop];
}


- (void) changeTrackerReceivedChange: (NSDictionary*)change {
    SequenceNumber lastSequence = [[change objectForKey: @"seq"] longLongValue];
    NSString* docID = [change objectForKey: @"id"];
    if (!docID)
        return;
    BOOL deleted = [[change objectForKey: @"deleted"] isEqual: (id)kCFBooleanTrue];
    for (NSDictionary* changeDict in $castIf(NSArray, [change objectForKey: @"changes"])) {
        NSString* revID = $castIf(NSString, [changeDict objectForKey: @"rev"]);
        if (!revID)
            continue;
        TDRevision* rev = [[TDRevision alloc] initWithDocID: docID revID: revID deleted: deleted];
        rev.sequence = lastSequence;
        [self addToInbox: rev];
        [rev release];
    }
}


- (void) changeTrackerStopped:(TDChangeTracker *)tracker {
    LogTo(Sync, @"%@: ChangeTracker stopped", self);
    [_changeTracker release];
    _changeTracker = nil;
    
    [self flushInbox];
    [self stop];
}


- (void) processInbox: (TDRevisionList*)inbox {
    // Ask the local database which of the revs are not known to it:
    LogTo(SyncVerbose, @"TDPuller: Looking up %@", inbox);
    if (![_db findMissingRevisions: inbox]) {
        Warn(@"TDPuller failed to look up local revs");
        return;
    }
    if (inbox.count == 0)
        return;
    LogTo(Sync, @"%@ fetching %u remote revisions...", self, inbox.count);
    
    // Fetch and add each of the new revs:
    for (TDRevision* rev in inbox) {
        [self pullRemoteRevision: rev];
    }
}


// Fetches the contents of a revision from the remote db, including its parent revision ID.
// The contents are stored into rev.properties.
- (void) pullRemoteRevision: (TDRevision*)rev
{
    NSString* path = $sprintf(@"/%@?rev=%@&revs=true", rev.docID, rev.revID);
    [self sendAsyncRequest: @"GET" path: path body: nil
          onCompletion: ^(NSDictionary *properties, NSError *error) {
              if (!properties)
                  return;  // GET failed
              
              NSArray* history = nil;
              NSDictionary* revisions = $castIf(NSDictionary,
                                                [properties objectForKey: @"_revisions"]);
              if (revisions) {
                  // Extract the history, expanding the numeric prefixes:
                  __block int start = [[revisions objectForKey: @"start"] intValue];
                  NSArray* revIDs = $castIf(NSArray, [revisions objectForKey: @"ids"]);
                  history = [revIDs my_map: ^(id revID) {
                      return (start ? $sprintf(@"%d-%@", start--, revID) : revID);
                  }];
                  
                  // Now remove the _revisions dict so it doesn't get stored in the local db:
                  NSMutableDictionary* editedProperties = [[properties mutableCopy] autorelease];
                  [editedProperties removeObjectForKey: @"_revisions"];
                  properties = editedProperties;
              }
              rev.properties = properties;

              // Add to batcher ... eventually it will be fed to -insertRevisions:.
              [_revsToInsert queueObject: $array(rev, history)];
          }
     ];
}


// This will be called when _revsToInsert fills up:
- (void) insertRevisions:(NSArray *)revs {
    LogTo(Sync, @"%@ inserting %u revisions...", self, revs.count);
    SequenceNumber maxSequence = self.lastSequence.longLongValue;
    [_db beginTransaction];
    
    for (NSArray* revAndHistory in revs) {
        TDRevision* rev = [revAndHistory objectAtIndex: 0];
        NSArray* history = [revAndHistory objectAtIndex: 1];
        // Insert the revision:
        maxSequence = MAX(maxSequence, rev.sequence);
        int status = [_db forceInsert: rev revisionHistory: history source: _remote];
        if (status >= 300) {
            if (status == 403)
                LogTo(Sync, @"%@: Remote rev failed validation: %@", self, rev);
            else
                Warn(@"%@ failed to write %@: status=%d", self, rev, status);
        }
    }
    
    // Remember we've received this sequence:
    if (maxSequence > self.lastSequence.longLongValue)
        self.lastSequence = $sprintf(@"%lld", maxSequence);
    
    [_db endTransaction];
    LogTo(Sync, @"%@ finished inserting %u revisions", self, revs.count);
}


@end