//
//  NSManagedObject+JSONHelpers.m
//  Gathering
//
//  Created by Saul Mora on 6/28/11.
//  Copyright 2011 Magical Panda Software LLC. All rights reserved.
//

#import "CoreData+MagicalRecord.h"
#import <objc/runtime.h>

void MR_swizzle(Class c, SEL orig, SEL new);

NSString * const kMagicalRecordImportCustomDateFormatKey = @"dateFormat";
NSString * const kMagicalRecordImportDefaultDateFormatString = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
NSString * const kMagicalRecordImportAttributeKeyMapKey = @"mappedKeyName";
NSString * const kMagicalRecordImportAttributeValueClassNameKey = @"attributeValueClassName";

NSString * const kMagicalRecordImportRelationshipMapKey = @"mappedKeyName";
NSString * const kMagicalRecordImportRelationshipPrimaryKey = @"primaryRelationshipKey";
NSString * const kMagicalRecordImportRelationshipTypeKey = @"type";


#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

@implementation NSManagedObject (MagicalRecord_DataImport)

- (NSString *) MR_primaryKeyAttributeName;
{
    return [[[self entity] MR_primaryKeyAttribute] name];
}

- (id) MR_valueForAttribute:(NSAttributeDescription *)attributeInfo fromObjectData:(NSDictionary *)objectData forKeyPath:(NSString *)keyPath
{
    id value = [objectData valueForKeyPath:keyPath];
    
    NSAttributeType attributeType = [attributeInfo attributeType];
    NSString *desiredAttributeType = [[attributeInfo userInfo] valueForKey:kMagicalRecordImportAttributeValueClassNameKey];
    if (desiredAttributeType) 
    {
        if ([desiredAttributeType hasSuffix:@"Color"])
        {
            value = colorFromString(value);
        }
    }
    else 
    {
        if (attributeType == NSDateAttributeType)
        {
            if (![value isKindOfClass:[NSDate class]]) 
            {
                NSString *dateFormat = [[attributeInfo userInfo] valueForKey:kMagicalRecordImportCustomDateFormatKey];
                value = dateFromString([value description], dateFormat ?: kMagicalRecordImportDefaultDateFormatString);
            }
            value = adjustDateForDST(value);
        }
    }
    
    return value == [NSNull null] ? nil : value;
}

- (BOOL) MR_importValue:(id)value forKey:(NSString *)key
{
    NSString *selectorString = [NSString stringWithFormat:@"import%@:", [key MR_capitalizedFirstCharaterString]];
    SEL selector = NSSelectorFromString(selectorString);
    if ([self respondsToSelector:selector])
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:selector withObject:value];
#pragma clang diagnostic pop
        return YES;
    }
    return NO;
}

- (void) MR_setAttributes:(NSDictionary *)attributes forKeysWithDictionary:(id)objectData
{    
    for (NSString *attributeName in attributes) 
    {
        NSAttributeDescription *attributeInfo = [attributes valueForKey:attributeName];
        NSString *lookupKeyPath = [objectData MR_lookupKeyForAttribute:attributeInfo];
        
        if (lookupKeyPath) 
        {
            id value = [self MR_valueForAttribute:attributeInfo fromObjectData:objectData forKeyPath:lookupKeyPath];
            if (![self MR_importValue:value forKey:attributeName])
            {
                [self setValue:value forKey:attributeName];
            }
        }
    }
}

- (NSManagedObject *) MR_findObjectForRelationship:(NSRelationshipDescription *)relationshipInfo withData:(id)singleRelatedObjectData
{
    NSEntityDescription *destinationEntity = [relationshipInfo destinationEntity];
    NSManagedObject *objectForRelationship = nil;
    id relatedValue = [singleRelatedObjectData MR_relatedValueForRelationship:relationshipInfo];

    if (relatedValue) 
    {
        NSManagedObjectContext *context = [self managedObjectContext];
        Class managedObjectClass = NSClassFromString([destinationEntity managedObjectClassName]);
        objectForRelationship = [managedObjectClass MR_findFirstByAttribute:[relationshipInfo MR_primaryKey]
                                                               withValue:relatedValue
                                                               inContext:context];
    }

    return objectForRelationship;
}

- (void) MR_addObject:(NSManagedObject *)relatedObject forRelationship:(NSRelationshipDescription *)relationshipInfo
{
    NSAssert2(relatedObject != nil, @"Cannot add nil to %@ for attribute %@", NSStringFromClass([self class]), [relationshipInfo name]);    
    NSAssert2([relatedObject entity] == [relationshipInfo destinationEntity], @"related object entity %@ not same as destination entity %@", [relatedObject entity], [relationshipInfo destinationEntity]);

    //add related object to set
    NSString *addRelationMessageFormat = @"set%@:";
    id relationshipSource = self;
    if ([relationshipInfo isToMany]) 
    {
        addRelationMessageFormat = @"add%@Object:";
        if ([relationshipInfo respondsToSelector:@selector(isOrdered)] && [relationshipInfo isOrdered])
        {
            //Need to get the ordered set
            NSString *selectorName = [[relationshipInfo name] stringByAppendingString:@"Set"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            relationshipSource = [self performSelector:NSSelectorFromString(selectorName)];
#pragma clang diagnostic pop
            addRelationMessageFormat = @"addObject:";
        }
    }

    NSString *addRelatedObjectToSetMessage = [NSString stringWithFormat:addRelationMessageFormat, attributeNameFromString([relationshipInfo name])];
 
    SEL selector = NSSelectorFromString(addRelatedObjectToSetMessage);
    
    @try 
    {
        [relationshipSource performSelector:selector withObject:relatedObject];        
    }
    @catch (NSException *exception) 
    {
        MRLog(@"Adding object for relationship failed: %@\n", relationshipInfo);
        MRLog(@"relatedObject.entity %@", [relatedObject entity]);
        MRLog(@"relationshipInfo.destinationEntity %@", [relationshipInfo destinationEntity]);
        MRLog(@"Add Relationship Selector: %@", addRelatedObjectToSetMessage);   
        MRLog(@"perform selector error: %@", exception);
    }
}

- (void) MR_setRelationships:(NSDictionary *)relationships forKeysWithDictionary:(NSDictionary *)relationshipData withBlock:(void(^)(NSRelationshipDescription *,id))setRelationshipBlock
{
    for (NSString *relationshipName in relationships) 
    {
        if ([self MR_importValue:relationshipData forKey:relationshipName]) 
        {
            continue;
        }
        
        NSRelationshipDescription *relationshipInfo = [relationships valueForKey:relationshipName];
        
        NSString *lookupKey = [[relationshipInfo userInfo] valueForKey:kMagicalRecordImportRelationshipMapKey] ?: relationshipName;
        id relatedObjectData = [relationshipData valueForKey:lookupKey];
        
        if (relatedObjectData == nil || [relatedObjectData isEqual:[NSNull null]]) 
        {
            continue;
        }
        
        SEL shouldImportSelector = NSSelectorFromString([NSString stringWithFormat:@"shouldImport%@:", [relationshipName MR_capitalizedFirstCharaterString]]);
        BOOL implementsShouldImport = (BOOL)[self respondsToSelector:shouldImportSelector];
        void (^establishRelationship)(NSRelationshipDescription *, id) = ^(NSRelationshipDescription *blockInfo, id blockData)
        {
            if (!(implementsShouldImport && !(BOOL)[self performSelector:shouldImportSelector withObject:relatedObjectData]))
            {
                setRelationshipBlock(blockInfo, blockData);
            }
        };
        
        if ([relationshipInfo isToMany])
        {
            for (id singleRelatedObjectData in relatedObjectData) 
            {
                establishRelationship(relationshipInfo, singleRelatedObjectData);
            }
        }
        else
        {
            establishRelationship(relationshipInfo, relatedObjectData);
        }
    }
}

- (BOOL) MR_preImport:(id)objectData;
{
    if ([self respondsToSelector:@selector(shouldImport:)])
    {
        BOOL shouldImport = (BOOL)[self performSelector:@selector(shouldImport:) withObject:objectData];
        if (!shouldImport) 
        {
            //            NSLog(@"Not importing: %@", objectData);
            return NO;
        }
    }   

    if ([self respondsToSelector:@selector(willImport:)])
    {
        [self performSelector:@selector(willImport:) withObject:objectData];
    }
    MR_swizzle([objectData class], @selector(valueForUndefinedKey:), @selector(MR_valueForUndefinedKey:));
    return YES;
}

- (BOOL) MR_postImport:(id)objectData;
{
    MR_swizzle([objectData class], @selector(valueForUndefinedKey:), @selector(MR_valueForUndefinedKey:));
    if ([self respondsToSelector:@selector(didImport:)])
    {
        [self performSelector:@selector(didImport:) withObject:objectData];
    }
    return YES;
}

- (BOOL) MR_importValuesForKeysWithObject:(id)objectData
{
    BOOL didStartimporting = [self MR_preImport:objectData];
    if (!didStartimporting) return NO;
    
    NSDictionary *attributes = [[self entity] attributesByName];
    [self MR_setAttributes:attributes forKeysWithDictionary:objectData];
    
    NSDictionary *relationships = [[self entity] relationshipsByName];
    [self MR_setRelationships:relationships
        forKeysWithDictionary:objectData 
                    withBlock:^(NSRelationshipDescription *relationshipInfo, id objectData){

         NSManagedObject *relatedObject = nil;
         relatedObject = [[relationshipInfo destinationEntity] MR_createInstanceFromObject:objectData inContext:[self managedObjectContext]];
         [relatedObject MR_importValuesForKeysWithObject:objectData];

         [self MR_addObject:relatedObject forRelationship:relationshipInfo];            
    }];

    return [self MR_postImport:objectData];
}

- (BOOL) MR_updateValuesForKeysWithObject:(id)objectData
{
    BOOL didStartimporting = [self MR_preImport:objectData];
    if (!didStartimporting) return NO;
    
    NSDictionary *attributes = [[self entity] attributesByName];
    [self MR_setAttributes:attributes forKeysWithDictionary:objectData];
    
    NSDictionary *relationships = [[self entity] relationshipsByName];
    [self MR_setRelationships:relationships
        forKeysWithDictionary:objectData 
                    withBlock:^(NSRelationshipDescription *relationshipInfo, id objectData) {
                        
         NSManagedObject *relatedObject = [self MR_findObjectForRelationship:relationshipInfo
                                                                    withData:objectData];
         if (relatedObject == nil)
         {
             relatedObject = [[relationshipInfo destinationEntity] MR_createInstanceFromObject:objectData inContext:[self managedObjectContext]];
         }
         else
         {
             [relatedObject MR_importValuesForKeysWithObject:objectData];
         }
         
         [self MR_addObject:relatedObject forRelationship:relationshipInfo];            
    }];
    
    return [self MR_postImport:objectData];
}

+ (id) MR_importFromObject:(id)objectData inContext:(NSManagedObjectContext *)context;
{
    NSManagedObject *managedObject = [self MR_createInContext:context];
    [managedObject MR_importValuesForKeysWithObject:objectData];
    return managedObject;
}

+ (id) MR_importFromObject:(id)objectData
{
    return [self MR_importFromObject:objectData inContext:[NSManagedObjectContext MR_defaultContext]];
}

+ (id) MR_updateFromObject:(id)objectData inContext:(NSManagedObjectContext *)context
{
    NSAttributeDescription *primaryAttribute = [[self MR_entityDescription] MR_primaryKeyAttribute];
    
    id value = [objectData MR_valueForAttribute:primaryAttribute];
    
    NSManagedObject *managedObject = [self MR_findFirstByAttribute:[primaryAttribute name] withValue:value inContext:context];
    if (!managedObject) 
    {
        managedObject = [self MR_createInContext:context];
        [managedObject MR_importValuesForKeysWithObject:objectData];
    }
    else
    {
        [managedObject MR_updateValuesForKeysWithObject:objectData];
    }
    return managedObject;
}

+ (id) MR_updateFromObject:(id)objectData
{
    return [self MR_updateFromObject:objectData inContext:[NSManagedObjectContext MR_defaultContext]];
}

+ (NSArray *) MR_importFromArray:(NSArray *)listOfObjectData
{
    return [self MR_importFromArray:listOfObjectData inContext:[NSManagedObjectContext MR_defaultContext]];
}

+ (NSArray *) MR_importFromArray:(NSArray *)listOfObjectData inContext:(NSManagedObjectContext *)context
{
    NSMutableArray *objectIDs = [NSMutableArray array];
    
    [MagicalRecord saveWithBlock:^(NSManagedObjectContext *localContext) 
    {    
        [listOfObjectData enumerateObjectsWithOptions:0 usingBlock:^(id obj, NSUInteger idx, BOOL *stop) 
        {
            NSDictionary *objectData = (NSDictionary *)obj;

            NSManagedObject *dataObject = [self MR_importFromObject:objectData inContext:localContext];

            if ([context obtainPermanentIDsForObjects:[NSArray arrayWithObject:dataObject] error:nil])
            {
              [objectIDs addObject:[dataObject objectID]];
            }
        }];
    }];
    
    return [self MR_findAllWithPredicate:[NSPredicate predicateWithFormat:@"self IN %@", objectIDs] inContext:context];
}

+ (NSArray *) MR_updateFromArray:(NSArray *)listOfObjectData;
{
    return [self MR_updateFromArray:listOfObjectData inContext:[NSManagedObjectContext MR_defaultContext]];
}

+ (NSArray *) MR_updateFromArray:(NSArray *)listOfObjectData inContext:(NSManagedObjectContext *)context;
{
    NSMutableArray *objectIDs = [NSMutableArray array];
    
    [MagicalRecord saveWithBlock:^(NSManagedObjectContext *localContext) 
     {    
         [listOfObjectData enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
             
              NSDictionary *objectData = (NSDictionary *)obj;
              
              NSManagedObject *dataObject = [self MR_importFromObject:objectData inContext:localContext];
              
              if ([context obtainPermanentIDsForObjects:[NSArray arrayWithObject:dataObject] error:nil])
              {
                  [objectIDs addObject:[dataObject objectID]];
              }
          }];
     }];
    
    return [self MR_findAllWithPredicate:[NSPredicate predicateWithFormat:@"self IN %@", objectIDs] inContext:context];
}

@end

#pragma clang diagnostic pop

void MR_swizzle(Class c, SEL orig, SEL new)
{
    Method origMethod = class_getInstanceMethod(c, orig);
    Method newMethod = class_getInstanceMethod(c, new);
    if (class_addMethod(c, orig, method_getImplementation(newMethod), method_getTypeEncoding(newMethod)))
    {
        class_replaceMethod(c, new, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    }
    else
    {
        method_exchangeImplementations(origMethod, newMethod);
    }
}