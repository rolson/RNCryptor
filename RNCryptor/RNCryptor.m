//
//  RNCryptor.m
//
//  Copyright (c) 2012 Rob Napier
//
//  This code is licensed under the MIT License:
//
//  Permission is hereby granted, free of charge, to any person obtaining a 
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//

#import "RNCryptor.h"

NSUInteger kSmallestBlockSize = 1024;

NSString *const kRNCryptorErrorDomain = @"net.robnapier.RNCryptManager";

static NSUInteger NextMultipleOfUnit(NSUInteger size, NSUInteger unit)
{
  return ((size + unit - 1) / unit) * unit;
}

@interface NSInputStream (RNCryptor)
- (BOOL)_RNGetData:(NSData **)data maxLength:(NSUInteger)maxLength error:(NSError **)error;
@end

@implementation NSInputStream (RNCryptor)
- (BOOL)_RNGetData:(NSData **)data maxLength:(NSUInteger)maxLength error:(NSError **)error
{
  NSMutableData *buffer = [NSMutableData dataWithLength:maxLength];
  if ([self read:buffer.mutableBytes maxLength:maxLength] < 0)
  {
    if (error)
    {
      *error = [self streamError];
      return NO;
    }
  }

  *data = buffer;
  return YES;
}
@end

@interface NSOutputStream (RNCryptor)
- (BOOL)_RNWriteData:(NSData *)data error:(NSError **)error;
@end

@implementation NSOutputStream (RNCryptor)
- (BOOL)_RNWriteData:(NSData *)data error:(NSError **)error
{
  // Writing 0 bytes will close the output stream.
  // This is an undocumented side-effect. radar://9930518
  if (data.length > 0)
  {
    NSInteger bytesWritten = [self write:data.bytes
                               maxLength:data.length];
    if (bytesWritten != data.length)
    {
      if (error)
      {
        *error = [self streamError];
      }
      return NO;
    }
  }
  return YES;
}
@end

@implementation RNCryptor
@synthesize settings = settings_;

- (RNCryptor *)initWithSettings:(RNCryptorSettings *)settings
{
  self = [super init];
  if (self)
  {
    settings_ = settings;
  }
  return self;
}

+ (RNCryptor *)AES256Cryptor
{
  static dispatch_once_t once;
  static RNCryptor *AES256Cryptor = nil;

  dispatch_once(&once, ^{ AES256Cryptor = [[self alloc] initWithSettings:[RNCryptorSettings AES256Settings]]; });
  return AES256Cryptor;
}

- (NSData *)randomDataOfLength:(size_t)length
{
  NSMutableData *data = [NSMutableData dataWithLength:length];

  int result = SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes);
  NSAssert(result == 0, @"Unable to generate random bytes: %d", errno);

  return data;
}

- (NSData *)keyForPassword:(NSString *)password salt:(NSData *)salt
{
  NSMutableData *derivedKey = [NSMutableData dataWithLength:self.settings.keySize];

  int result = CCKeyDerivationPBKDF(kCCPBKDF2,            // algorithm
                                    password.UTF8String,  // password
                                    password.length,  // passwordLength
                                    salt.bytes,           // salt
                                    salt.length,          // saltLen
                                    kCCPRFHmacAlgSHA1,    // PRF
                                    self.settings.PBKDFRounds,         // rounds
                                    derivedKey.mutableBytes, // derivedKey
                                    derivedKey.length); // derivedKeyLen

  // Do not log password here
  NSAssert(result == kCCSuccess, @"Unable to create AES key for password: %d", result);

  return derivedKey;
}

- (BOOL)processResult:(CCCryptorStatus)cryptorStatus
                data:(NSMutableData *)outData
               length:(size_t)length
             callback:(RNCryptorWriteCallback)writeCallback
               output:(NSOutputStream *)output
                error:(NSError **)error
{
  if (cryptorStatus != kCCSuccess)
  {
    if (error)
    {
      *error = [NSError errorWithDomain:kRNCryptorErrorDomain code:cryptorStatus userInfo:nil];
    }
    return NO;
  }

  if (length > 0)
  {
    [outData setLength:length];

    [output open];
    NSInteger bytesWritten = [output write:outData.bytes maxLength:outData.length];
    if (bytesWritten != outData.length)
    {
      if (error)
      {
        *error = [output streamError];
      }
      return NO;
    }

    if (writeCallback)
    {
      writeCallback(outData);
    }
  }
  return YES;
}

// Reads from stream up to length bytes. Blocks until it reaches the end of the stream, or fills the buffer.
- (NSMutableData *)readStream:(NSInputStream *)stream length:(NSUInteger)maxLength
{
  NSMutableData *data = [NSMutableData dataWithLength:maxLength];
  uint8_t *readPtr = [data mutableBytes];
  NSUInteger availableLength = maxLength;
  [stream open];

  while (availableLength > 0 && [stream streamStatus] != NSStreamStatusAtEnd && [stream streamStatus] != NSStreamStatusError)
  {
    NSInteger readLength = [stream read:readPtr maxLength:availableLength];
    if (readLength >= 0)
    {
      readPtr += readLength;
      availableLength -= readLength;
    }
    else
    {
      return nil;
    }
  }
  [data setLength:maxLength - availableLength];
  return data;
}

- (BOOL)performOperation:(CCOperation)anOperation
              fromStream:(NSInputStream *)aFromStream
            readCallback:(RNCryptorReadCallback)aReadCallback
                toStream:(NSOutputStream *)aToStream
           writeCallback:(RNCryptorWriteCallback)aWriteCallback
           encryptionKey:(NSData *)anEncryptionKey
                      IV:(NSData *)anIV
             footerSize:(NSUInteger)aFooterSize
                 footer:(NSData **)aFooter
                   error:(NSError **)anError
{
 // Create the cryptor
  CCCryptorRef cryptor = NULL;
  CCCryptorStatus cryptorStatus;
  cryptorStatus = CCCryptorCreateWithMode(anOperation,
                                          self.settings.mode,
                                          self.settings.algorithm,
                                          self.settings.padding,
                                          anIV.bytes,
                                          anEncryptionKey.bytes,
                                          anEncryptionKey.length,
                                          NULL, // tweak
                                          0, // tweakLength
                                          0, // numRounds (0=default)
                                          self.settings.modeOptions,
                                          &cryptor);

  if (cryptorStatus != kCCSuccess || cryptor == NULL)
  {
    if (anError)
    {
      *anError = [NSError errorWithDomain:kRNCryptorErrorDomain code:cryptorStatus userInfo:nil];
    }
    NSAssert(NO, @"Could not create cryptor: %d", cryptorStatus);
    return NO;
  }

  const NSUInteger bufferSize = NextMultipleOfUnit(MAX(aFooterSize + 1, kSmallestBlockSize), self.settings.blockSize);
  NSMutableData *readBuffer = [NSMutableData data];

  // Read ahead
  NSMutableData *readAheadBuffer = [self readStream:aFromStream length:bufferSize];

  NSMutableData *outData = [NSMutableData data];
  BOOL stop = NO;
  size_t dataOutMoved;
  while (!stop)
  {
    // Error
    if ([aFromStream streamStatus] == NSStreamStatusError)
    {
      *anError = [aFromStream streamError];
      CCCryptorRelease(cryptor);
      return NO;
    }

    // Not at end (read-ahead has a full block). Read another block.
    if ([aFromStream streamStatus] != NSStreamStatusAtEnd)
    {
      readBuffer = readAheadBuffer;
      readAheadBuffer = [self readStream:aFromStream length:bufferSize];
    }

    // At end now?
    if ([aFromStream streamStatus] == NSStreamStatusAtEnd)
    {
      // Put everything together
      [readBuffer appendData:readAheadBuffer];
      readAheadBuffer = nil;
      stop = YES;
      if (aFooter && aFooterSize > 0)
      {
        *aFooter = [readBuffer subdataWithRange:NSMakeRange([readBuffer length] - aFooterSize, aFooterSize)];
        [readBuffer setLength:[readBuffer length] - aFooterSize];
      }
    }

    if (aReadCallback)
    {
      aReadCallback(readBuffer);
    }
    [outData setLength:CCCryptorGetOutputLength(cryptor, [readBuffer length], true)];
    cryptorStatus = CCCryptorUpdate(cryptor,       // cryptor
                                    readBuffer.bytes,      // dataIn
                                    readBuffer.length,     // dataInLength (verified > 0 above)
                                    outData.mutableBytes,      // dataOut
                                    outData.length, // dataOutAvailable
                                    &dataOutMoved);   // dataOutMoved
    if (![self processResult:cryptorStatus data:outData length:dataOutMoved callback:aWriteCallback output:aToStream error:anError])
    {
      CCCryptorRelease(cryptor);
      return NO;
    }
  }

  [outData setLength:CCCryptorGetOutputLength(cryptor, bufferSize, true)];

   // Write the final block
   cryptorStatus = CCCryptorFinal(cryptor,        // cryptor
                                  outData.mutableBytes,       // dataOut
                                  outData.length,  // dataOutAvailable
                                  &dataOutMoved);    // dataOutMoved
  if (![self processResult:cryptorStatus data:outData length:dataOutMoved callback:aWriteCallback output:aToStream error:anError])
   {
     CCCryptorRelease(cryptor);
     return NO;
   }

   CCCryptorRelease(cryptor);
   return YES;
}

- (BOOL)decryptFromStream:(NSInputStream *)input
                 toStream:(NSOutputStream *)output
            encryptionKey:(NSData *)encryptionKey
                       IV:(NSData *)IV
                  HMACKey:(NSData *)HMACKey
                    error:(NSError **)error
{
  RNCryptorWriteCallback readCallback = nil;
  __block CCHmacContext HMACContext;

  if (HMACKey)
  {
    CCHmacInit(&HMACContext, kCCHmacAlgSHA1, HMACKey.bytes, HMACKey.length);

    readCallback = ^void(NSData *readData) {
      CCHmacUpdate(&HMACContext, readData.bytes, readData.length);
    };
  }

  NSData *streamHMACData;
  BOOL result = [self performOperation:kCCDecrypt
                              fromStream:input
                            readCallback:readCallback
                                toStream:output
                           writeCallback:nil
                           encryptionKey:encryptionKey
                                      IV:IV
                              footerSize:HMACKey ? self.settings.HMACLength : 0
                                  footer:&streamHMACData
                                   error:error];

  if (result && HMACKey)
  {
    NSMutableData *computedHMACData = [NSMutableData dataWithLength:self.settings.HMACLength];
    CCHmacFinal(&HMACContext, [computedHMACData mutableBytes]);

    if (! [computedHMACData isEqualToData:streamHMACData])
    {
      result = NO;
      *error = [NSError errorWithDomain:kRNCryptorErrorDomain code:1 userInfo:nil]; // FIXME: Better error reports
    }
  }

  return result;
}

- (BOOL)decryptFromStream:(NSInputStream *)input toStream:(NSOutputStream *)output password:(NSString *)password error:(NSError **)error
{
  NSData *encryptionKeySalt;
  NSData *HMACKeySalt;
  NSData *IV;
  NSData *header;

  [input open];
  if (! [input _RNGetData:&header maxLength:2 error:error] ||
      ! [input _RNGetData:&encryptionKeySalt maxLength:self.settings.saltSize error:error] ||
      ! [input _RNGetData:&HMACKeySalt maxLength:self.settings.saltSize error:error] ||
      ! [input _RNGetData:&IV maxLength:self.settings.blockSize error:error])
  {
    return NO;
  }

  uint8_t AES128CryptorHeader[2] = {0, 0};
  if (![header isEqualToData:[NSData dataWithBytes:AES128CryptorHeader length:sizeof(AES128CryptorHeader)]])
  {
    *error = [NSError errorWithDomain:kRNCryptorErrorDomain code:1 userInfo:nil]; // FIXME: error
    return NO;
  }

  NSData *encryptionKey = [self keyForPassword:password salt:encryptionKeySalt];
  NSData *HMACKey = [self keyForPassword:password salt:HMACKeySalt];

  return [self decryptFromStream:input toStream:output encryptionKey:encryptionKey IV:IV HMACKey:HMACKey error:error];
}

- (BOOL)decryptFromURL:(NSURL *)inURL toURL:(NSURL *)outURL append:(BOOL)append password:(NSString *)password error:(NSError **)error
{
  NSInputStream *decryptInputStream = [NSInputStream inputStreamWithURL:inURL];
  NSOutputStream *decryptOutputStream = [NSOutputStream outputStreamWithURL:outURL append:append];

  BOOL result = [self decryptFromStream:decryptInputStream toStream:decryptOutputStream password:password error:error];

  [decryptOutputStream close];
  [decryptInputStream close];

  return result;
}


- (NSData *)decryptData:(NSData *)ciphertext password:(NSString *)password error:(NSError **)error
{
  NSInputStream *decryptInputStream = [NSInputStream inputStreamWithData:ciphertext];
  NSOutputStream *decryptOutputStream = [NSOutputStream outputStreamToMemory];

  BOOL result = [self decryptFromStream:decryptInputStream toStream:decryptOutputStream password:password error:error];

  [decryptOutputStream close];
  [decryptInputStream close];

  if (result)
  {
    return [decryptOutputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
  }
  else
  {
    return nil;
  }
}

- (BOOL)encryptFromStream:(NSInputStream *)input
                 toStream:(NSOutputStream *)output
            encryptionKey:(NSData *)encryptionKey
                       IV:(NSData *)IV
                  HMACKey:(NSData *)HMACKey
                    error:(NSError **)error
{
  RNCryptorWriteCallback writeCallback = nil;
  __block CCHmacContext HMACContext;

  if (HMACKey)
  {
    CCHmacInit(&HMACContext, kCCHmacAlgSHA1, HMACKey.bytes, HMACKey.length);

    writeCallback = ^void(NSData *writeData) {
      CCHmacUpdate(&HMACContext, writeData.bytes, writeData.length);
    };
  }

  BOOL result = [self performOperation:kCCEncrypt
                              fromStream:input
                            readCallback:nil
                                toStream:output
                           writeCallback:writeCallback
                           encryptionKey:encryptionKey
                                      IV:IV
                              footerSize:0
                                  footer:nil
                                   error:error];

  if (HMACKey && result)
  {
    NSMutableData *HMACData = [NSMutableData dataWithLength:self.settings.HMACLength];
    CCHmacFinal(&HMACContext, [HMACData mutableBytes]);

    if (! [output _RNWriteData:HMACData error:error])
    {
      return NO;
    }
  }

  return result;
}
- (BOOL)encryptFromStream:(NSInputStream *)input toStream:(NSOutputStream *)output password:(NSString *)password error:(NSError **)error
{
  NSData *encryptionKeySalt = [self randomDataOfLength:self.settings.saltSize];
  NSData *encryptionKey = [self keyForPassword:password salt:encryptionKeySalt];

  NSData *HMACKeySalt = [self randomDataOfLength:self.settings.saltSize];
  NSData *HMACKey = [self keyForPassword:password salt:HMACKeySalt];

  NSData *IV = [self randomDataOfLength:self.settings.blockSize];

  [output open];
  uint8_t header[2] = {0, 0};
  NSData *headerData = [NSData dataWithBytes:header length:sizeof(header)];
  if (! [output _RNWriteData:headerData error:error] ||
      ! [output _RNWriteData:encryptionKeySalt error:error] ||
      ! [output _RNWriteData:HMACKeySalt error:error] ||
      ! [output _RNWriteData:IV error:error]
    )
  {
    return NO;
  }

  return [self encryptFromStream:input toStream:output encryptionKey:encryptionKey IV:IV HMACKey:HMACKey error:error];
}

- (BOOL)encryptFromURL:(NSURL *)inURL toURL:(NSURL *)outURL append:(BOOL)append password:(NSString *)password error:(NSError **)error
{
  NSInputStream *encryptInputStream = [NSInputStream inputStreamWithURL:inURL];
  [encryptInputStream open];
  if (!encryptInputStream)
  {
    if (error)
    {
      *error = [NSError errorWithDomain:kRNCryptorErrorDomain code:1 userInfo:nil]; // FIXME: Error
    }
    return NO;
  }

  NSOutputStream *encryptOutputStream = [NSOutputStream outputStreamWithURL:outURL append:append];
  [encryptOutputStream open];
  if (!encryptOutputStream)
  {
    if (error)
    {
      *error = [NSError errorWithDomain:kRNCryptorErrorDomain code:1 userInfo:nil]; // FIXME: Error
    }
    return NO;
  }

  BOOL result = [self encryptFromStream:encryptInputStream toStream:encryptOutputStream password:password error:error];

  [encryptOutputStream close];
  [encryptInputStream close];

  return result;
}

- (NSData *)encryptData:(NSData *)plaintext password:(NSString *)password error:(NSError **)error
{
  NSInputStream *encryptInputStream = [NSInputStream inputStreamWithData:plaintext];
  NSOutputStream *encryptOutputStream = [NSOutputStream outputStreamToMemory];

  BOOL result = [self encryptFromStream:encryptInputStream toStream:encryptOutputStream password:password error:error];

  [encryptOutputStream close];
  [encryptInputStream close];

  if (result)
  {
    return [encryptOutputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
  }
  else
  {
    return nil;
  }
}

@end

@implementation RNCryptorSettings
@synthesize algorithm = algorithm_;
@synthesize keySize = keySize_;
@synthesize blockSize = blockSize_;
@synthesize IVSize = IVSize_;
@synthesize saltSize = saltSize_;
@synthesize PBKDFRounds = PBKDFRounds_;
@synthesize HMACAlgorithm = HMACAlgorithm_;
@synthesize HMACLength = HMACLength_;
@synthesize mode = mode_;
@synthesize padding = padding_;
@synthesize modeOptions = modeOptions_;


+ (RNCryptorSettings *)AES256Settings
{
  static dispatch_once_t once;
  static RNCryptorSettings *AES256Settings;

  dispatch_once(&once, ^{
    AES256Settings = [[self alloc] init];
    AES256Settings->algorithm_ = kCCAlgorithmAES128;
    AES256Settings->mode_ = kCCModeCTR;
    AES256Settings->modeOptions_ = kCCModeOptionCTR_LE;
    AES256Settings->keySize_ = kCCKeySizeAES256;
    AES256Settings->blockSize_ = kCCBlockSizeAES128;
    AES256Settings->IVSize_ = kCCBlockSizeAES128;
    AES256Settings->padding_ = ccNoPadding;
    AES256Settings->saltSize_ = 8;
    AES256Settings->PBKDFRounds_ = 10000; // ~80ms on an iPhone 4
    AES256Settings->HMACAlgorithm_ = kCCHmacAlgSHA256;
    AES256Settings->HMACLength_= CC_SHA256_DIGEST_LENGTH;
  });
  return AES256Settings;
}

@end