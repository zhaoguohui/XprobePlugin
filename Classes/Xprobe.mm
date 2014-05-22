//
//  Xprobe.m
//  XprobePlugin
//
//  Created by John Holdsworth on 17/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  For full licensing term see https://github.com/johnno1962/XprobePlugin
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "Xprobe.h"
#import "Xtrace.h"

#import <objc/runtime.h>
#import <vector>
#import <map>

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

BOOL logXprobeSweep;

struct _xsweep { unsigned sequence, depth; const char *type; };

static struct _xsweep sweepState;

static std::map<__unsafe_unretained id,struct _xsweep> instancesSeen;
static std::map<__unsafe_unretained Class,std::vector<__unsafe_unretained id> > instancesByClass;

static NSMutableArray *paths;

@interface NSObject(XprobeReferences)

- (id)xvalueForMethod:(Method)method;
- (id)xvalueForIvar:(Ivar)ivar;

- (NSArray *)subviews;
- (id)contentView;
- (id)document;
- (id)delegate;
- (id)target;

@end

/*****************************************************
 ******** classes that go to make up a path **********
 *****************************************************/

@interface _Xpath : NSObject
@property int pathID;
@end

@implementation _Xpath

+ (id)withPathID:(int)pathID {
    _Xpath *path = [self new];
    path.pathID = pathID;
    return path;
}

- (int)xadd {
    int newPathID = (int)[paths count];
    [paths addObject:self];
    return newPathID;
}

- (id)object {
    return [paths[self.pathID] object];
}

- (id)aClass {
    return [[self object] class];
}

@end

@interface _Xretained : _Xpath
@property (nonatomic,retain) id object;
@end

@implementation _Xretained
@end

@interface _Xassigned : _Xpath
@property (nonatomic,assign) id object;
@end

@implementation _Xassigned
@end

@interface _Xivar : _Xpath
@property const char *name;
@end

@implementation _Xivar

- (id)object {
    id obj = [super object];
    Ivar ivar = class_getInstanceVariable([obj class], self.name);
    return [obj xvalueForIvar:ivar];
}

@end

@interface _Xmethod : _Xpath
@property SEL name;
@end

@implementation _Xmethod

- (id)object {
    id obj = [super object];
    Method method = class_getInstanceMethod([obj class], self.name);
    return [obj xvalueForMethod:method];
}

@end

@interface _Xarray : _Xpath
@property NSUInteger sub;
@end

@implementation _Xarray

- (NSArray *)array {
    return [super object];
}

- (id)object {
    NSArray *arr = [self array];
    if ( self.sub < [arr count] )
        return arr[self.sub];
    NSLog( @"Xprobe: %@ reference %d beyond end of array %d",
          NSStringFromClass([self class]), (int)self.sub, (int)[arr count] );
    return nil;
}

@end

@interface Xset : _Xarray
@end

@implementation Xset

- (NSArray *)array {
    return [[paths[self.pathID] object] allObjects];
}

@end

@interface _Xview : _Xarray
@end

@implementation _Xview

- (NSArray *)array {
    return [[paths[self.pathID] object] subviews];
}

@end

@interface _Xdict : _Xpath
@property id sub;
@end

@implementation _Xdict

- (id)object {
    return [super object][self.sub];
}

@end

@interface _Xsuper : _Xpath
@property Class aClass;
@end

@implementation _Xsuper
@end

// class without instance
@interface _Xclass : _Xsuper
@end

@implementation _Xclass

- (id)object {
    return self;
}

@end

/*****************************************************
 ********* generic ivar/method/type access ***********
 *****************************************************/

@implementation NSObject(Xprobe)

- (id)xvalueForIvar:(Ivar)ivar {
    const char *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    return [self xvalueForPointer:iptr type:ivar_getTypeEncoding(ivar)];
}

- (id)xvalueForMethod:(Method)method {
    const char *type = method_getTypeEncoding(method);
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setSelector:method_getName(method)];
    [invocation invokeWithTarget:self];

    NSUInteger size = 0, align;
    const char *returnType = [sig methodReturnType];
    NSGetSizeAndAlignment(returnType, &size, &align);

    char buffer[size];
    if ( type[0] != 'v' )
        [invocation getReturnValue:buffer];
    return [self xvalueForPointer:buffer type:returnType];
}

- (id)xvalueForPointer:(const char *)iptr type:(const char *)type {
    switch ( type[0] ) {
        case 'V':
        case 'v': return @"void";
        case 'B': return @(*(bool *)iptr);
        case 'c': return @(*(char *)iptr);
        case 'C': return @(*(unsigned char *)iptr);
        case 's': return @(*(short *)iptr);
        case 'S': return @(*(unsigned short *)iptr);
        case 'i': return @(*(int *)iptr);
        case 'I': return @(*(unsigned *)iptr);

        case 'f': return @(*(float *)iptr);
        case 'd': return @(*(double *)iptr);

#ifndef __LP64__
        case 'q': return @(*(long long *)iptr);
#else
        case 'q':
#endif
        case 'l': return @(*(long *)iptr);
#ifndef __LP64__
        case 'Q': return @(*(unsigned long long *)iptr);
#else
        case 'Q':
#endif
        case 'L': return @(*(unsigned long *)iptr);

        case '@': return *((const id *)(void *)iptr);
        case ':': return NSStringFromSelector(*(SEL *)iptr);
        case '#': {
            Class aClass = *(const Class *)(void *)iptr;
            return aClass ? [NSString stringWithFormat:@"[%@ class]", aClass] : @"Nil";
        }
        case '^': return [NSValue valueWithPointer:*(void **)iptr];

        case '{': try {
            char type2[1000], *tptr = type2;
            while ( *type )
                if ( *type == '"' ) {
                    while ( *++type != '"' )
                        ;
                    type++;
                }
                else
                    *tptr++ = *type++;
            *tptr = '\000';
            return [NSValue valueWithBytes:iptr objCType:type2];
        }
            catch ( NSException *e ) {
                return @"raised exception";
            }
        case '*': {
            const char *ptr = *(const char **)iptr;
            return ptr ? [NSString stringWithUTF8String:ptr] : @"NULL";
        }
        case 'b':
            return [NSString stringWithFormat:@"0x%08x", *(int *)iptr];
        default:
            return @"unknown type";
    }
}

- (BOOL)xvalueForIvar:(Ivar)ivar update:(NSString *)value {
    const char *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    const char *type = ivar_getTypeEncoding(ivar);
    switch ( type[0] ) {
        case 'B': *(bool *)iptr = [value intValue]; break;
        case 'c': *(char *)iptr = [value intValue]; break;
        case 'C': *(unsigned char *)iptr = [value intValue]; break;
        case 's': *(short *)iptr = [value intValue]; break;
        case 'S': *(unsigned short *)iptr = [value intValue]; break;
        case 'i': *(int *)iptr = [value intValue]; break;
        case 'I': *(unsigned *)iptr = [value intValue]; break;
        case 'f': *(float *)iptr = [value floatValue]; break;
        case 'd': *(double *)iptr = [value doubleValue]; break;
#ifndef __LP64__
        case 'q': *(long long *)iptr = [value longLongValue]; break;
#else
        case 'q':
#endif
        case 'l': *(long *)iptr = (long)[value longLongValue]; break;
#ifndef __LP64__
        case 'Q': *(unsigned long long *)iptr = [value longLongValue]; break;
#else
        case 'Q':
#endif
        case 'L': *(unsigned long *)iptr = (unsigned long)[value longLongValue]; break;
        case ':': *(SEL *)iptr = NSSelectorFromString(value); break;
        default:
            NSLog( @"Xprobe: update of unknown type: %s", type );
            return FALSE;
    }

    return TRUE;
}

- (NSString *)xtype:(const char *)type {
    NSString *typeStr = [self _xtype:type];
    return [NSString stringWithFormat:@"<span class=%@>%@</span>",
            [typeStr hasSuffix:@"*"] ? @"classStyle" : @"typeStyle", typeStr];
}

- (NSString *)_xtype:(const char *)type {
    switch ( type[0] ) {
        case 'V': return @"oneway void";
        case 'v': return @"void";
        case 'B': return @"bool";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned";
        case 'f': return @"float";
        case 'd': return @"double";
#ifndef __LP64__
        case 'q': return @"long long";
#else
        case 'q':
#endif
        case 'l': return @"long";
#ifndef __LP64__
        case 'Q': return @"unsigned long long";
#else
        case 'Q':
#endif
        case 'L': return @"unsigned long";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '@': return [self xtype:type+1 star:" *"];
        case '^': return [self xtype:type+1 star:" *"];
        case '{': return [self xtype:type star:""];
        case 'r':
            return [@"const " stringByAppendingString:[self xtype:type+1]];
        case '*': return @"char *";
        default:
            return [NSString stringWithUTF8String:type]; //@"id";
    }
}

- (NSString *)xtype:(const char *)type star:(const char *)star {
    if ( type[-1] == '@' ) {
        if ( type[0] != '"' )
            return @"id";
        else if ( type[1] == '<' )
            type++;
    }
    if ( type[-1] == '^' && type[0] != '{' )
        return [[self xtype:type] stringByAppendingString:@" *"];

    const char *end = ++type;
    while ( isalpha(*end) || *end == '_' || *end == ',' )
        end++;
    if ( type[-1] == '<' )
        return [NSString stringWithFormat:@"id&lt;%@&gt;",
                [self xlinkForProtocol:[NSString stringWithFormat:@"%.*s", (int)(end-type), type]]];
    else {
        NSString *className = [NSString stringWithFormat:@"%.*s", (int)(end-type), type];
        return [NSString stringWithFormat:@"<span onclick=\\'this.id=\"%@\"; "
                "prompt( \"class:\", \"%@\" ); event.cancelBubble=true;\\'>%@</span>%s",
                className, className, className, star];
    }
}

- (NSString *)xlinkForProtocol:(NSString *)protoName {
    return [NSString stringWithFormat:@"<a href=\\'#\\' onclick=\\'this.id=\"%@\"; prompt( \"protocol:\", \"%@\" ); "
            "event.cancelBubble = true; return false;\\'>%@</a>", protoName, protoName, protoName];
}

/*****************************************************
 ********* sweep and object display methods **********
 *****************************************************/

- (void)xsweep {
    const char *className = class_getName([self class]);
    if ( logXprobeSweep )
        printf( "Xprobe sweep %d: <%s %p>\n", sweepState.depth, className, self);

    // avoid scanning legacy classes
    BOOL legacy = [Xprobe xprobeExclude:className];
    NSMutableArray *references = [NSMutableArray new];

    for ( Class aClass = [self class] ; aClass && aClass != [NSObject class] ; aClass = [aClass superclass] ) {
        if ( className[1] != '_' )
            instancesByClass[aClass].push_back(self);
        if ( legacy )
            continue;

        unsigned ic;
        Ivar *ivars = class_copyIvarList(aClass, &ic);
        for ( unsigned i=0 ; i<ic ; i++ )
            if ( ivar_getTypeEncoding(ivars[i])[0] == '@' ) {
                id ref = [self xvalueForIvar:ivars[i]];
                if ( ref && ref != self )
                    [references addObject:ref];
            }

        free( ivars );
    }

    sweepState.type = "I";
    [references xsweep];

    sweepState.type = "P";
    if ( [self respondsToSelector:@selector(target)] && [self target] )
        [@[[self target]] xsweep];
    if ( [self respondsToSelector:@selector(delegate)] && [self delegate] )
        [@[[self delegate]] xsweep];
    if ( [self respondsToSelector:@selector(document)] && [self document] )
        [@[[self document]] xsweep];

    sweepState.type = "W";
    if ( [self respondsToSelector:@selector(contentView)] && [self contentView] )
        [@[[self contentView]] xsweep];

    sweepState.type = "V";
    if ( [self respondsToSelector:@selector(subviews)] )
        [[self subviews] xsweep];
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    _Xpath *path = paths[pathID];
    Class aClass = [path aClass];

    NSString *closer = [NSString stringWithFormat:@"<span onclick=\\'prompt(\"close:\",\"%d\"); "
                        "event.cancelBubble = true;\\'>%s</span>", pathID, class_getName(aClass)];
    [html appendFormat:[self class] == aClass ? @"<b>%@</b>" : @"%@", closer];

    if ( [aClass superclass] ) {
        _Xsuper *superPath = [path class] == [_Xclass class] ? [_Xclass new] :
            [_Xsuper withPathID:[path class] == [_Xsuper class] ? path.pathID : pathID];
        superPath.aClass = [aClass superclass];
        
        [html appendString:@" : "];
        [self xlinkForCommand:@"open" withPathID:[superPath xadd] into:html];
    }

    unsigned c;
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(aClass, &c);
    if ( c ) {
        [html appendString:@" <"];
        for ( unsigned i=0 ; i<c ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protoName = NSStringFromProtocol(protos[i]);
            [html appendString:[self xlinkForProtocol:protoName]];
        }
        [html appendString:@">"];
        free( protos );
    }

    [html appendString:@" {<br>"];

    Ivar *ivars = class_copyIvarList(aClass, &c);
    for ( unsigned i=0 ; i<c ; i++ ) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        [html appendFormat:@" &nbsp; &nbsp;%@ ", [self xtype:type]];
        [self xspanForPathID:pathID ivar:ivars[i] into:html];
        [html appendString:@";<br>"];
    }

    [html appendFormat:@"} "];
    [self xlinkForCommand:@"properties" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"methods" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"siblings" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"trace" withPathID:pathID into:html];

    if ( [self respondsToSelector:@selector(subviews)] ) {
        [html appendFormat:@" "];
        [self xlinkForCommand:@"render" withPathID:pathID into:html];
        [html appendFormat:@" "];
        [self xlinkForCommand:@"views" withPathID:pathID into:html];
    }

    [html appendFormat:@" "];
    [html appendFormat:@" <a href=\\'#\\' onclick=\\'prompt(\"close:\",\"%d\"); return false;\\'>close</a>", pathID];
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:html
{
    Class linkClass = [paths[pathID] aClass];
    unichar firstChar = toupper([which characterAtIndex:0]);

    BOOL basic = [which isEqualToString:@"open"] || [which isEqualToString:@"close"];
    NSString *label = !basic ? which : [self class] != linkClass ? NSStringFromClass(linkClass) :
        [NSString stringWithFormat:@"&lt;%s %p&gt;", class_getName([self class]), self];

    [html appendFormat:@"<span id=\\'%@%d\\'><a href=\\'#\\' onclick=\\'prompt( \"%@:\", \"%d\" ); "
        "event.cancelBubble = true; return false;\\'>%@</a>%@",
        basic ? @"" : [NSString stringWithCharacters:&firstChar length:1],
        pathID, which, pathID, label, [which isEqualToString:@"close"] ? @"" : @"</span>"];
}

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar into:(NSMutableString *)html {
    const char *type = ivar_getTypeEncoding(ivar);
    const char *name = ivar_getName(ivar);
    _Xpath *path = paths[pathID];

    [html appendFormat:@"<span onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { this.id =\"I%d\"; "
        "prompt( \"ivar:\", \"%d,%s\" ); event.cancelBubble = true; }\\'>%s", pathID, pathID, name, name];

    if ( [path class] != [_Xclass class] ) {
        [html appendString:@" = "];
        if ( type[0] != '@' )
            [html appendFormat:@"<span onclick=\\'this.id =\"E%d\"; prompt( \"edit:\", \"%d,%s\" ); "
                "event.cancelBubble = true;\\'>%@</span>", pathID, pathID, name, [self xvalueForIvar:ivar]];
        else {
            id subObject = [self xvalueForIvar:ivar];
            if ( subObject ) {
                _Xivar *path = [_Xivar withPathID:pathID];
                path.name = ivar_getName(ivar);
                [subObject xlinkForCommand:@"open" withPathID:[path xadd] into:html];
            }
            else
                [html appendString:@"nil"];
        }
    }

    [html appendString:@"</span>"];
}

@end

@implementation NSSet(Xprobe)

- (void)xsweep {
    sweepState.type = "S";
    [[self allObjects] xsweep];
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"["];
    for ( int i=0 ; i<[self count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        Xset *path = [Xset withPathID:pathID];
        path.sub = i;
        [[self allObjects][i] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
    }
    [html appendString:@"]"];
}

@end

@implementation NSArray(Xprobe)

- (void)xsweep {
    ++sweepState.depth;
    const char *type = sweepState.type;
    for ( NSObject *obj in self ) {
        if ( instancesSeen.find(obj) == instancesSeen.end() ) {
            instancesSeen[obj] = sweepState;
            sweepState.sequence++;
            [obj xsweep];
        }
        sweepState.type = type;
    }
    sweepState.depth--;
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"("];
    for ( int i=0 ; i<[self count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        _Xarray *path = [_Xarray withPathID:pathID];
        path.sub = i;
        [self[i] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
    }
    [html appendString:@")"];
}

@end

@implementation NSDictionary(Xprobe)

- (void)xsweep {
    sweepState.type = "D";
    [[self allValues] xsweep];
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"{<br>"];

    NSArray *keys = [self allKeys];
    for ( int i=0 ; i<[keys count] ; i++ ) {
        [html appendFormat:@" &nbsp; &nbsp;%@ => ", keys[i]];
        _Xdict *path = [_Xdict withPathID:pathID];
        path.sub = keys[i];
        [self[keys[i]] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@",<br>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSString(Xprobe)

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendFormat:@"@\"%@\"", [self stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]];
}

@end

@implementation NSValue(Xprobe)

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendFormat:@"%@", self];
}

@end

@implementation NSData(Xprobe)

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendFormat:@"%@", self];
}

@end

@implementation NSRegularExpression(Xprobe)

+ (NSRegularExpression *)xsimpleRegexp:(NSString *)pattern {
    NSError *error = nil;
    NSRegularExpression *regexp = [[NSRegularExpression alloc] initWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:&error];
    if ( error && [pattern length] )
        NSLog( @"Xprobe: Filter compilation error: %@, in pattern: \"%@\"", [error localizedDescription], pattern );
    return regexp;
}

- (BOOL)xmatches:(NSString *)str  {
    return [self rangeOfFirstMatchInString:str options:0 range:NSMakeRange(0, [str length])].location != NSNotFound;
}

@end

/*****************************************************
 ********* implmentation of Xprobe service ***********
 *****************************************************/

#import <netinet/tcp.h>
#import <sys/socket.h>
#import <arpa/inet.h>

static BOOL retainObjects;
static int clientSocket;

@implementation Xprobe

+ (NSString *)revision {
    return @"$Id: //depot/XprobePlugin/Classes/Xprobe.mm#4 $";
}

+ (BOOL)xprobeExclude:(const char *)className {
    return className[0] == '_' || strncmp(className, "WebHistory", 10) == 0 ||
        strncmp(className, "NS", 2) == 0 || strncmp(className, "XC", 2) == 0 ||
        strncmp(className, "IDE", 3) == 0 || strncmp(className, "DVT", 3) == 0 ||
        strncmp(className, "Xcode3", 6) == 0 ||strncmp(className, "IB", 2) == 0;
}

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain {

    retainObjects = shouldRetain;

    NSLog( @"Xprobe: Connecting to %s", ipAddress );

    if ( clientSocket ) {
        close( clientSocket );
        [NSThread sleepForTimeInterval:.5];
    }

    struct sockaddr_in loaderAddr;

    loaderAddr.sin_family = AF_INET;
	inet_aton( ipAddress, &loaderAddr.sin_addr );
	loaderAddr.sin_port = htons(XPROBE_PORT);

    int optval = 1;
    if ( (clientSocket = socket(loaderAddr.sin_family, SOCK_STREAM, 0)) < 0 )
        NSLog( @"Xprobe: Could not open socket for injection: %s", strerror( errno ) );
    else if ( setsockopt( clientSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0 )
        NSLog( @"Xprobe: Could not set TCP_NODELAY: %s", strerror( errno ) );
    else if ( connect( clientSocket, (struct sockaddr *)&loaderAddr, sizeof loaderAddr ) < 0 )
        NSLog( @"Xprobe: Could not connect: %s", strerror( errno ) );
    else
        [self performSelectorInBackground:@selector(service) withObject:nil];
}

+ (void)service {

    uint32_t magic = XPROBE_MAGIC;
    if ( write(clientSocket, &magic, sizeof magic ) != sizeof magic )
        return;

    [self writeString:[[NSBundle mainBundle] bundleIdentifier]];
    
    while ( clientSocket ) {
        NSString *command = [self readString];
        if ( !command ) break;
        NSString *argument = [self readString];
        if ( !argument ) break;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:NSSelectorFromString(command) withObject:argument];
#pragma clang diagnostic pop
    }

    NSLog( @"Xprobe: Service loop exits" );
}

+ (NSString *)readString {
    uint32_t length;
    ssize_t sofar = 0, bytes;

    if ( read(clientSocket, &length, sizeof length) != sizeof length ) {
        NSLog( @"Xprobe: Socket read error %s", strerror(errno) );
        return nil;
    }

    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read(clientSocket, buff+sofar, length-sofar )) > 0 )
        sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"Xprobe: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        free( buff );
        return nil;
    }

    if ( buff )
        buff[sofar] = '\000';

    NSString *str = [NSString stringWithUTF8String:buff];
    free( buff );
    return str;
}

+ (void)writeString:(NSString *)str {
    const char *data = [str UTF8String];
    uint32_t length = (uint32_t)strlen(data);

    if ( !clientSocket )
        NSLog( @"Xprobe: Write to closed" );
    else if ( write(clientSocket, &length, sizeof length ) != sizeof length ||
             write(clientSocket, data, length ) != length )
        NSLog( @"Xprobe: Socket write error %s", strerror(errno) );
}

+ (void)search:(NSString *)pattern {
    NSArray *roots = [self sweepForPattern:pattern];
    NSMutableString *html = [NSMutableString new];
    [html appendString:@"document.body.innerHTML = '"];

    paths = [NSMutableArray new];

    for ( int i=0 ; i<[roots count] ; i++ ) {
        struct _xsweep &info = instancesSeen[roots[i]];
        _Xretained *path = retainObjects ? [_Xretained new] : (_Xretained *)[_Xassigned new];
        path.object = roots[i];

        for ( unsigned i=1 ; i<info.depth ; i++ )
            [html appendString:@"&nbsp; &nbsp; "];
        //[html appendFormat:@"%s ", info.type];

        [roots[i] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@"<br>"];
    }

    [html appendString:@"';"];
    [self writeString:html];
}

+ (NSArray *)sweepForPattern:(NSString *)classPattern {

    sweepState.sequence = sweepState.depth = 0;
    sweepState.type = "R";

    instancesSeen.clear();
    instancesByClass.clear();

    [[self xprobeSeeds] xsweep];

    NSRegularExpression *classRegexp = [NSRegularExpression xsimpleRegexp:classPattern];
    NSMutableArray *liveObjects = [NSMutableArray new];
    std::map<__unsafe_unretained id,int> added;

    for ( const auto &byClass : instancesByClass )
        if ( !classRegexp || [classRegexp xmatches:NSStringFromClass(byClass.first)] )
            for ( const auto &instance : byClass.second )
                if ( !added[instance]++ )
                    [liveObjects addObject:instance];

    [liveObjects sortUsingComparator:^NSComparisonResult( __unsafe_unretained id obj1, __unsafe_unretained id obj2 ) {
        return instancesSeen[obj1].sequence < instancesSeen[obj2].sequence ? NSOrderedAscending :
            instancesSeen[obj1].sequence > instancesSeen[obj2].sequence ? NSOrderedDescending : NSOrderedSame;
    }];

    return liveObjects;
}

+ (void)open:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('%d').outerHTML = '", pathID];
    [obj xlinkForCommand:@"close" withPathID:pathID into:html];
    [html appendString:@"<br><table><tr><td class=indent><td class=drilldown>"];
    [obj xopenWithPathID:pathID into:html];
    [html appendString:@"</table></span>';"];
    [self writeString:html];
}

+ (void)close:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('%d').outerHTML = '", pathID];
    [obj xlinkForCommand:@"open" withPathID:pathID into:html];
    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)properties:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('P%d').outerHTML = '<span class=propsStyle><br><br>", pathID];

    unsigned pc;
    objc_property_t *props = class_copyPropertyList(aClass, &pc);
    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        [html appendFormat:@"@property () %@ <span onclick=\\'this.id =\"P%d\"; "
            "prompt( \"property:\", \"%d,%s\" ); event.cancelBubble = true;\\'>%s</span>; // %s<br>",
            [self xtype:attrs+1], pathID, pathID, name, name, attrs];
    }

    if ( props )
        free( props );

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)methods:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('M%d').outerHTML = '<br><span class=methodStyle>"
        "Method Filter: <input type=textfield size=10 onchange=\\'methodFilter(this);\\'>", pathID];

    Class stopClass = aClass == [NSObject class] ? Nil : [NSObject class];
    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
        [self dumpMethodType:"+" forClass:object_getClass(bClass) original:aClass pathID:pathID into:html];

    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
        [self dumpMethodType:"-" forClass:bClass original:aClass pathID:pathID into:html];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)dumpMethodType:(const char *)mtype forClass:(Class)aClass original:(Class)original
                 pathID:(int)pathID into:(NSMutableString *)html {
    unsigned mc;
    Method *methods = class_copyMethodList(aClass, &mc);
    NSString *hide = aClass == original ? @"" :
        [NSString stringWithFormat:@" style=\\'display:none;\\' title=\\'%s\\'", class_getName(aClass)];

    if ( mc && ![hide length] )
        [html appendString:@"<br>"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(method_getName(methods[i]));
        const char *type = method_getTypeEncoding(methods[i]);
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
        NSArray *bits = [[NSString stringWithUTF8String:name] componentsSeparatedByString:@":"];

        [html appendFormat:@"<div sel=\\'%s\\'%@>%s (%@)", name, hide, mtype, [self xtype:[sig methodReturnType]]];
        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", bits[a-2], [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"M%d\"; prompt( \"method:\", \"%d,%s\" );"
             "event.cancelBubble = true;\\'>%s</span> ", pathID, pathID, name, name];

        [html appendFormat:@";</div>"];
    }

    if ( methods )
        free( methods );
}

+ (void)protocol:(NSString *)protoName {
    Protocol *proto = NSProtocolFromString(protoName);
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('%@').outerHTML = '<span id=\\'%@\\' "
        "onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { prompt( \"_protocol:\", \"%@\"); "
        "event.cancelBubble = true; }\\'><a href=\\'#\\' onclick=\\'prompt( \"_protocol:\", \"%@\"); "
        "event.cancelBubble = true; return false;\\'>%@</a><p><table><tr><td><td class=indent><td>"
        "<span class=protoStyle>@protocol %@", protoName, protoName, protoName, protoName, protoName, protoName];

    unsigned pc;
    Protocol *__unsafe_unretained *protos = protocol_copyProtocolList(proto, &pc);
    if ( pc ) {
        [html appendString:@" <"];
        for ( unsigned i=0 ; i<pc ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protoName = NSStringFromProtocol(protos[i]);
            [html appendString:[self xlinkForProtocol:protoName]];
        }
        [html appendString:@">"];
        free( protos );
    }

    [html appendString:@"<br>"];
    
    objc_property_t *props = protocol_copyPropertyList(proto, &pc);

    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        [html appendFormat:@"@property () %@ %s; // %s<br>", [self xtype:attrs+1], name, attrs];
    }

    if ( props )
        free( props );

    [self dumpMethodsForProtocol:proto required:YES instance:NO into:html];
    [self dumpMethodsForProtocol:proto required:NO instance:NO into:html];
    [self dumpMethodsForProtocol:proto required:YES instance:YES into:html];
    [self dumpMethodsForProtocol:proto required:NO instance:YES into:html];

    [html appendString:@"<br>@end<p></span></table></span>';"];
    [self writeString:html];
}

// Thanks to http://bou.io/ExtendedTypeInfoInObjC.html !
extern "C" const char *_protocol_getMethodTypeEncoding(Protocol *,SEL,BOOL,BOOL);

+ (void)dumpMethodsForProtocol:(Protocol *)proto required:(BOOL)required instance:(BOOL)instance into:(NSMutableString *)html {
    unsigned mc;
    objc_method_description *methods = protocol_copyMethodDescriptionList( proto, required, instance, &mc );
    if ( mc )
        [html appendFormat:@"<br>@%@<br>", required ? @"required" : @"optional"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(methods[i].name);
        const char *type;// = methods[i].types;

        type = _protocol_getMethodTypeEncoding(proto,methods[i].name,required,instance);
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
        NSArray *parts = [[NSString stringWithUTF8String:name] componentsSeparatedByString:@":"];

        [html appendFormat:@"%s (%@)", instance ? "-" : "+", [self xtype:[sig methodReturnType]]];
        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", parts[a-2], [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"%s", name];

        [html appendFormat:@" ;<br>"];
    }
    
    if ( methods )
        free( methods );
}

+ (void)_protocol:(NSString *)protoName {
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('%@').outerHTML = '%@';",
     protoName, [html xlinkForProtocol:protoName]];
    [self writeString:html];
}

+ (void)views:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('V%d').outerHTML = '<br>", pathID];
    [self subviewswithPathID:pathID indent:0 into:html];
    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)subviewswithPathID:(int)pathID indent:(int)indent into:(NSMutableString *)html {
    id obj = [paths[pathID] object];
    for ( int i=0 ; i<indent ; i++ )
        [html appendString:@"&nbsp; &nbsp; "];
    [obj xlinkForCommand:@"open" withPathID:pathID into:html];
    [html appendString:@"<br>"];

    NSArray *subviews = [obj subviews];
    for ( int i=0 ; i<[subviews count] ; i++ ) {
        _Xview *path = [_Xview withPathID:pathID];
        path.sub = i;
        [self subviewswithPathID:[path xadd] indent:indent+1 into:html];
    }
}

+ (void)trace:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];
    Class aClass = [paths[pathID] aClass];

    [Xtrace setDelegate:self];
    [Xtrace traceInstance:obj class:aClass];
}

+ (void)xtrace:(NSString *)trace forInstance:(void *)obj {
    [self writeString:trace];
}

struct _xinfo { int pathID; id obj; Class aClass; NSString *name, *value; };

+ (struct _xinfo)parseInput:(NSString *)input {
    NSArray *parts = [input componentsSeparatedByString:@","];
    struct _xinfo info;

    info.pathID = [parts[0] intValue];
    info.obj = [paths[info.pathID] object];
    info.aClass = [paths[info.pathID] aClass];
    info.name = parts[1];

    if ( [parts count] >= 3 )
        info.value = parts[2];

    return info;
}

+ (void)ivar:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('I%d').outerHTML = '", info.pathID];
    [info.obj xspanForPathID:info.pathID ivar:ivar into:html];
    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)edit:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('E%d').outerHTML = '"
        "<span id=E%d><input type=textfield size=10 value=\\'%@\\' "
        "onchange=\\'prompt(\"save:\", \"%d,%@,\"+this.value );\\'></span>';",
         info.pathID, info.pathID, [info.obj xvalueForIvar:ivar], info.pathID, info.name];
    [self writeString:html];
}

+ (void)save:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    if ( !ivar )
        NSLog( @"Xprobe: could not find ivar \"%@\" in %@", info.name, info.obj);
    else
        if ( ![info.obj xvalueForIvar:ivar update:info.value] )
            NSLog( @"Xprobe: unable to update ivar \"%@\" in %@", info.name, info.obj);

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('E%d').outerHTML = '<span onclick=\\'"
        "this.id =\"E%d\"; prompt( \"edit:\", \"%d,%@\" ); event.cancelBubble = true;\\'><i>%@</i></span>';",
        info.pathID, info.pathID, info.pathID, info.name, [info.obj xvalueForIvar:ivar]];
    [self writeString:html];
}

+ (void)property:(NSString *)input {
    struct _xinfo info = [self parseInput:input];

    objc_property_t prop = class_getProperty(info.aClass, [info.name UTF8String]);
    char *getter = property_copyAttributeValue(prop, "G");
    SEL sel = sel_registerName( getter ? getter : [info.name UTF8String] );
    if ( getter ) free( getter );

    Method method = class_getInstanceMethod(info.aClass, sel);
    [self methodLinkFor:info method:method prefix:"P" command:"property:"];
}

+ (void)method:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Method method = class_getInstanceMethod(info.aClass, NSSelectorFromString(info.name));
    [self methodLinkFor:info method:method prefix:"M" command:"method:"];
}

+ (void)methodLinkFor:(struct _xinfo &)info method:(Method)method
               prefix:(const char *)prefix command:(const char *)command {
    id result = method ? [info.obj xvalueForMethod:method] : @"nomethod";

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('%s%d').outerHTML = '<span onclick=\\'"
        "this.id =\"%s%d\"; prompt( \"%s\", \"%d,%@\" ); event.cancelBubble = true;\\'>%@ = ",
        prefix, info.pathID, prefix, info.pathID, command, info.pathID, info.name, info.name];

    if ( result && method && method_getTypeEncoding(method)[0] == '@' ) {
        _Xmethod *subpath = [_Xmethod withPathID:info.pathID];
        subpath.name = method_getName(method);
        [result xlinkForCommand:@"open" withPathID:[subpath xadd] into:html];
    }
    else
        [html appendFormat:@"%@", result ? result : @"nil"];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)siblings:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('S%d').outerHTML = '<p>", pathID];

    for ( const auto &obj : instancesByClass[aClass] ) {
        _Xretained *path = [_Xretained new];
        path.object = obj;
        [obj xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@" "];
    }

    [html appendString:@"<p>';"];
    [self writeString:html];
}

+ (void)render:(NSString *)input {
    int pathID = [input intValue];
    __block NSData *data = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
        UIView *view = (UIView *)[paths[pathID] object];
        if ( ![view respondsToSelector:@selector(layer)] )
            return;

        UIGraphicsBeginImageContext(view.frame.size);
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        data = UIImagePNGRepresentation(image);
        UIGraphicsEndImageContext();
#else
        NSView *view = (NSView *)[paths[pathID] object];
        NSSize imageSize = view.bounds.size;
        if ( !imageSize.width || !imageSize.height )
            return;

        NSBitmapImageRep *bir = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bir];
        data = [bir representationUsingType:NSPNGFileType properties:nil];
#endif
    });

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('R%d').outerHTML = '<p><img src=\\'data:image/png;base64,%@\\'><p>';",
     pathID, [data base64EncodedStringWithOptions:0]];
    [self writeString:html];
}

+ (void)class:(NSString *)className {
    _Xclass *path = [_Xclass new];
    if ( !(path.aClass = NSClassFromString(className)) )
        return;

    int pathID = [path xadd];
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"document.getElementById('%@').outerHTML = '", className];
    [path xlinkForCommand:@"close" withPathID:pathID into:html];
    [html appendString:@"<br><table><tr><td class=indent><td class=drilldown>"];
    [path xopenWithPathID:pathID into:html];
    [html appendString:@"</table></span>';"];
    [self writeString:html];
}

@end
