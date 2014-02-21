//  NSString+Commands.m
//
//  MacPass
//
//  Created by Michael Starke on 10/11/13.
//  Copyright (c) 2013 HicknHack Software GmbH. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "NSString+Commands.h"
#import "KPKEntry.h"
#import "KPKAttribute.h"
#import "KPKTree.h"
#import "KPKGroup.h"
#import "KPKAutotypeCommands.h"
#import "NSUUID+KeePassKit.h"

static NSDictionary *_selectorForReference;

/**
 *  Cache Entry for Autotype Commands
 */
@interface KPKCommandCacheEntry : NSObject

@property (strong) NSDate *lastUsed;
@property (copy) NSString *command;

- (instancetype)initWithCommand:(NSString *)command;

@end

@implementation KPKCommandCacheEntry

- (instancetype)initWithCommand:(NSString *)command {
  self = [super init];
  if(self) {
    _lastUsed = [NSDate date];
    _command = [command copy];
  }
  return self;
}

@end

@interface KPKCommandCache : NSObject

+ (instancetype)sharedCache;

@end

/**
 *  Cache to store normalized Autoype command sequences
 */
static KPKCommandCache *_sharedKPKCommandCacheInstance;

@implementation KPKCommandCache

+ (instancetype)sharedCache {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _sharedKPKCommandCacheInstance = [[KPKCommandCache alloc] init];
  });
  return _sharedKPKCommandCacheInstance;
}

/**
 *  Safe short-formats than can directly be repalced with theri long versions
 */
- (NSDictionary *)shortFormats {
  static NSDictionary *shortFormats;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    shortFormats = @{
                     kKPKAutotypeShortBackspace : kKPKAutotypeBackspace,
                     kKPKAutotypeShortBackspace2 : kKPKAutotypeBackspace,
                     kKPKAutotypeShortDelete : kKPKAutotypeDelete,
                     kKPKAutotypeShortInsert : kKPKAutotypeInsert,
                     kKPKAutotypeShortSpace : kKPKAutotypeSpace
                     };
  });
  return shortFormats;
}
/**
 *  Short formats that contain modifier and cannot have to be considered spearately when replacing modifer
 */
- (NSDictionary *)unsafeShortFormats {
  static NSDictionary *unsafeShortFormats;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    unsafeShortFormats = @{
                           kKPKAutotypeShortAlt : kKPKAutotypeAlt,
                           kKPKAutotypeShortControl : kKPKAutotypeControl,
                           kKPKAutotypeShortEnter : kKPKAutotypeEnter,
                           kKPKAutotypeShortShift : kKPKAutotypeShift,
                           };
  });
  return unsafeShortFormats;
}
/**
 *  Commands that are using a number, but do not allow a repeat
 */
- (NSArray *)valueCommands {
  static NSArray *valueCommands;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    valueCommands = @[ kKPKAutotypeDelay,
                       kKPKAutotypeVirtualExtendedKey,
                       kKPKAutotypeVirtualKey,
                       kKPKAutotypeVirtualNonExtendedKey ];
  });
  return valueCommands;
}

- (NSString *)findCommand:(NSString *)command {
  /*
   Caches the entries in a NSDictionary with a maxium entry count
   If the maxium count is reached, the entries older than lifetime are removed
   */
  static NSUInteger const kMPMaximumCacheEntries = 50;
  static NSUInteger const kMPCacheLifeTime = 60*60*60; // 1h
  static NSMutableDictionary *cache = nil;
  if(nil == cache) {
    cache = [[NSMutableDictionary alloc] initWithCapacity:kMPMaximumCacheEntries];
  }
  KPKCommandCacheEntry *cacheHit = cache[command];
  if(!cacheHit) {
    cacheHit = [[KPKCommandCacheEntry alloc] initWithCommand:[self _normalizeCommand:command]];
    if([cache count] > kMPMaximumCacheEntries) {
      __block NSMutableArray *keysToRemove = [[NSMutableArray alloc] init];
      [cache enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        KPKCommandCacheEntry *entry = obj;
        if([entry.lastUsed timeIntervalSinceNow] > kMPCacheLifeTime) {
          [keysToRemove addObject:key];
        }
      }];
      [cache removeObjectsForKeys:keysToRemove];
    }
    cache[command] = cacheHit;
  }
  else {
    /* Update the cahce date since we hit it */
    cacheHit.lastUsed = [NSDate date];
  }
  return cacheHit.command;
}

- (NSString *)_normalizeCommand:(NSString *)command {
  /* Replace Curly brackest with our interal command so we can quickly find bracket missatches */
  if(!command) {
    return nil;
  }
  NSMutableString __block *mutableCommand = [command mutableCopy];
  [mutableCommand replaceOccurrencesOfString:kKPKAutotypeShortCurlyBracketLeft withString:kKPKAutotypeCurlyBracketLeft options:0 range:NSMakeRange(0, [mutableCommand length])];
  [mutableCommand replaceOccurrencesOfString:kKPKAutotypeShortCurlyBracketRight withString:kKPKAutotypeCurlyBracketRight options:0 range:NSMakeRange(0, [mutableCommand length])];
  
  if(![mutableCommand validateCommmand]) {
    return nil;
  }
  /*
   Since modifer keys can be used in curly brackets,
   we only can replace the non-braceds ones with ourt own modifer commands
   */
  NSString *modifierMatch = [[NSString alloc] initWithFormat:@"(?<!\\{)([\\%@|\\%@|%@|\\%@])(?!\\})", kKPKAutotypeShortAlt, kKPKAutotypeShortControl, kKPKAutotypeShortEnter, kKPKAutotypeShortShift];
  NSRegularExpression *modifierRegExp = [[NSRegularExpression alloc] initWithPattern:modifierMatch options:NSRegularExpressionCaseInsensitive error:0];
  NSAssert(modifierRegExp, @"Modifier RegExp should be correct!");
  NSMutableIndexSet __block *matchingIndices = [[NSMutableIndexSet alloc] init];
  [modifierRegExp enumerateMatchesInString:command options:0 range:NSMakeRange(0, [command length]) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
    [matchingIndices addIndex:result.range.location];
  }];
  /* Enumerate the indices backwards, to not invalidate them by replacing strings */
  NSDictionary *unsafeShortForats = [self unsafeShortFormats];
  [matchingIndices enumerateIndexesInRange:NSMakeRange(0, [command length]) options:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
    NSString *shortFormatKey = [mutableCommand substringWithRange:NSMakeRange(idx, 1)];
    [mutableCommand replaceCharactersInRange:NSMakeRange(idx, 1) withString:unsafeShortForats[shortFormatKey]];
  }];
  /*
   It's possible to extend commands by a mulitpyer,
   Simply just repeat the commands n-times
   
   Format is {<KEY> <Repeat>}
   
   Special versions are:
   {DELAY X}	Delays X milliseconds.
   {VKEY X}
   {VKEY-NX X}
   {VKEY-EX X}
   */
  /* TODO: - not matched */
  NSString *repeaterMatch = [[NSString alloc] initWithFormat:@"\\{([a-z]+|\\%@|\\%@|%@|\\%@)\\ ([0-9]*)\\}", kKPKAutotypeShortAlt, kKPKAutotypeShortControl, kKPKAutotypeShortEnter, kKPKAutotypeShortShift];
  NSRegularExpression *repeaterRegExp = [[NSRegularExpression alloc] initWithPattern:repeaterMatch options:NSRegularExpressionCaseInsensitive error:0];
  NSAssert(repeaterRegExp, @"Repeater RegExp should be corret!");
  NSMutableDictionary __block *repeaterValues = [[NSMutableDictionary alloc] init];
  [repeaterRegExp enumerateMatchesInString:mutableCommand options:0 range:NSMakeRange(0, [mutableCommand length]) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
    @autoreleasepool {
      NSString *key = [mutableCommand substringWithRange:result.range];
      NSString *command = [mutableCommand substringWithRange:[result rangeAtIndex:1]];
      if([[self valueCommands] containsObject:command]) {
        return; // Commands is not a repeat command
      }
      NSScanner *numberScanner = [[NSScanner alloc] initWithString:[mutableCommand substringWithRange:[result rangeAtIndex:2]]];
      NSInteger repeatCounter = 0;
      if(![numberScanner scanInteger:&repeatCounter]) {
        *stop = YES; // Abort!
      }
      NSMutableString *rolledOutRepeat = [[NSMutableString alloc] initWithCapacity:([command length] + 2) * repeatCounter];
      command = [NSString stringWithFormat:@"{%@}", command];
      while(repeatCounter-- > 0) {
        [rolledOutRepeat appendString:command];
      }
      repeaterValues[key] = rolledOutRepeat;
    }
  }];
  
  for(NSString *needle in repeaterValues) {
    [mutableCommand replaceOccurrencesOfString:needle withString:repeaterValues[needle] options:NSCaseInsensitiveSearch range:NSMakeRange(0, [mutableCommand length])];
  }
  
  NSDictionary *shortFormats = [self shortFormats];
  for(NSString *needle in shortFormats) {
    NSString *replace = shortFormats[needle];
    [mutableCommand replaceOccurrencesOfString:needle withString:replace options:NSCaseInsensitiveSearch range:NSMakeRange(0, [mutableCommand length])];
  }
  return [[NSString alloc] initWithString:mutableCommand];
}

@end


@implementation NSString (Autotype)

- (NSString *)normalizedAutotypeSequence {
  return [[KPKCommandCache sharedCache] findCommand:self];
}

- (BOOL)validateCommmand {
  if([self length] == 0) {
    return NO;
  }
  NSUInteger index = 0;
  BOOL isBracketOpen = NO;
  while(YES) {
    if(index >= [self length]) {
      /* At the end all brackests should be closed */
      return !isBracketOpen;
    }
    NSUInteger openingBracketIndex = [self rangeOfString:@"{" options:0 range:NSMakeRange(index, [self length] - index)].location;
    NSUInteger closingBracketIndex = [self rangeOfString:@"}" options:0 range:NSMakeRange(index, [self length] - index)].location;
    if(isBracketOpen) {
      if(closingBracketIndex != NSNotFound && closingBracketIndex < openingBracketIndex) {
        isBracketOpen = NO;
        index = (1 + closingBracketIndex);
        continue;
      }
      return NO; // Missing closing or we got another opening one before the next closing one
    }
    else if(openingBracketIndex != NSNotFound ) {
      if( openingBracketIndex < closingBracketIndex ) {
        isBracketOpen = YES;
        index = (1 + openingBracketIndex);
        continue;
      }
      return NO; // There is another closing braket before the opening one
    }
    return (closingBracketIndex == NSNotFound);
  }
}

@end

@implementation NSString (Reference)

/*
 References are formatted as follows:
 T	Title
 U	User name
 P	Password
 A	URL
 N	Notes
 I	UUID
 O	Other custom strings (KeePass 2.x only)
 
 {REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}
 {REF:<WantedField>@<SearchIn>:<Text>}
 */
- (NSString *)resolveReferencesWithTree:(KPKTree *)tree {
  return [self _resolveReferencesWithTree:tree recursionLevel:0];
}

- (NSString *)_resolveReferencesWithTree:(KPKTree *)tree recursionLevel:(NSUInteger)level {
  /* Stop endless recurstion at 10 substitions */
  if(level > 10) {
    return self;
  }
  NSRegularExpression *regexp = [NSRegularExpression regularExpressionWithPattern:@"\\{REF:(T|U|A|N|I|O){1}@(T|U|A|N|I){1}:([^\\}]*)\\}"
                                                                          options:NSRegularExpressionCaseInsensitive
                                                                            error:NULL];
  __block NSMutableString *mutableSelf = [self mutableCopy];
  __block BOOL didReplace = NO;
  [regexp enumerateMatchesInString:self options:0 range:NSMakeRange(0, [self length]) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
    NSString *valueField = [self substringWithRange:[result rangeAtIndex:1]];
    NSString *searchField = [self substringWithRange:[result rangeAtIndex:2]];
    NSString *criteria = [self substringWithRange:[result rangeAtIndex:3]];
    NSString *substitute = [self _retrieveValueOfKey:valueField
                                             withKey:searchField
                                            matching:criteria
                                            withTree:tree];
    didReplace = YES;
    [mutableSelf replaceCharactersInRange:result.range withString:substitute];
  }];
  return (didReplace ? [mutableSelf _resolveReferencesWithTree:tree recursionLevel:level+1] : self);
}

- (NSString *)_retrieveValueOfKey:(NSString *)valueKey withKey:(NSString *)searchKey matching:(NSString *)match withTree:(KPKTree *)tree {
  _selectorForReference = @{
                            @"T" : @"title",
                            @"U" : @"username",
                            @"P" : @"password",
                            @"A" : @"url",
                            @"N" : @"notes",
                            @"I" : @"uuid"
                            };
  NSString *valueSelectorString = _selectorForReference[valueKey];
  if(!valueSelectorString) {
    return nil; // Wrong valueKey
  }
  __block KPKEntry *matchingEntry;
  /* Custom Attribute search */
  if([searchKey isEqualToString:@"O"]) {
    [tree.allEntries enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      KPKEntry *entry = obj;
      for(KPKAttribute *attribute in entry.customAttributes) {
        if([attribute.value isEqualToString:match]) {
          matchingEntry = obj;
          *stop = YES;
        }
      }
    }];
  }
  /* Direct UUID search */
  else if([searchKey isEqualToString:@"I"]) {
    NSUUID *uuid;
    if([match length] == 32) {
      uuid = [[NSUUID alloc] initWithUndelemittedUUIDString:match];
    }
    else {
      uuid = [[NSUUID alloc] initWithUUIDString:match];
    }
    matchingEntry = [tree.root entryForUUID:uuid];
  }
  /* Defautl attribute search */
  else {
    NSString *predicateFormat = [[NSString alloc] initWithFormat:@"SELF.%@ CONTAINS[cd] %@", valueSelectorString, match];
    NSPredicate *searchPredicat = [NSPredicate predicateWithFormat:predicateFormat];
    matchingEntry = [tree.allEntries filteredArrayUsingPredicate:searchPredicat][0];
  }
  if(!matchingEntry) {
    return nil;
  }
  SEL selector = NSSelectorFromString(valueSelectorString);
  NSMethodSignature *signatur = [matchingEntry methodSignatureForSelector:selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signatur];
  [invocation setSelector:selector];
  [invocation setTarget:matchingEntry];
  [invocation invoke];
  
  CFTypeRef result;
  [invocation getReturnValue:&result];
  if (result) {
    CFRetain(result);
    NSString *string = (NSString *)CFBridgingRelease(result);
    return string;
  }
  return nil;
}

@end

@implementation NSString (Placeholder)

- (NSString *)evaluatePlaceholderWithEntry:(KPKEntry *)entry {
  /* build mapping for all default fields */
  NSMutableDictionary *mappings = [[NSMutableDictionary alloc] initWithCapacity:0];
  for(KPKAttribute *defaultAttribute in [entry defaultAttributes]) {
    NSString *keyString = [[NSString alloc] initWithFormat:@"{%@}", defaultAttribute.key];
    mappings[keyString] = defaultAttribute.value;
  }
  /*
   Custom String fields {S:<Key>}
   */
  for(KPKAttribute *customAttribute in [entry customAttributes]) {
    NSString *keyString = [[NSString alloc] initWithFormat:@"{S:%@}", customAttribute.key ];
    mappings[keyString] = customAttribute.value;
  }
  /*  url mappings */
  if([entry.url length] > 0) {
    NSURL *url = [[NSURL alloc] initWithString:entry.url];
    if([url scheme]) {
      NSMutableString *mutableURL = [entry.url mutableCopy];
      [mutableURL replaceOccurrencesOfString:[url scheme] withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [mutableURL length])];
      mappings[@"{URL:RMVSCM}"] = [mutableURL copy];
      mappings[@"{URL:SCM}"] = [url scheme];
    }
    else {
      mappings[@"{URL:RMVSCM}"] = entry.url;
      mappings[@"{URL:SCM}"] = @"";
    }
    mappings[@"{URL:HOST}"] = [url host] ? [url host] : @"";
    mappings[@"{URL:PORT}"] = [url port] ? [[url port]stringValue] : @"";
    mappings[@"{URL:PATH}"] = [url path] ? [url path] : @"";
    mappings[@"{URL:QUERY}"] = [url query] ? [url query] : @"";
  }
  NSMutableString *supstitudedString = [self mutableCopy];
  for(NSString *placeholderKey in mappings) {
    [supstitudedString replaceOccurrencesOfString:placeholderKey
                                       withString:mappings[placeholderKey]
                                          options:NSCaseInsensitiveSearch
                                            range:NSMakeRange(0, [supstitudedString length])];
  }
  // TODO Missing recursion!
  return [supstitudedString copy];
}
@end
