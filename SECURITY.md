# Security Documentation - Kuralis

## 🔐 Token Encryption Implementation

Kuralis implements **Active Record Encryption** to protect sensitive API tokens stored in the database. This ensures that even if the database is compromised, the tokens remain secure.

### **What's Encrypted**

#### **Shop Model (`shops` table)**
- `shopify_token` - Shopify API access token

#### **ShopifyEbayAccount Model (`shopify_ebay_accounts` table)**  
- `access_token` - eBay API access token
- `refresh_token` - eBay API refresh token

### **Encryption Method**

- **Algorithm**: AES-256-GCM (industry standard)
- **Key Management**: Rails credentials (encrypted at rest)
- **Deterministic Encryption**: Used for fields that need to be searchable
- **Non-deterministic Encryption**: Used for maximum security on sensitive tokens

## 🚀 **Migration Process**

### **Step 1: Run the Migration**
```bash
rails db:migrate
```

This migration:
- Creates backup columns for existing tokens
- Copies current tokens to backup columns  
- Clears the original token columns
- Prepares for re-encryption

### **Step 2: Re-encrypt Existing Data**
```bash
rails db:encryption:migrate_tokens
```

This task:
- Reads tokens from backup columns
- Re-saves them using Rails encryption
- Verifies encryption is working correctly
- Provides status updates

### **Step 3: Verify Encryption**
```bash
rails db:encryption:verify
```

This task:
- Confirms encryption is properly configured
- Shows token statistics
- Checks for remaining backup columns

### **Step 4: Clean Up (Optional)**
```bash
rails db:encryption:cleanup_backups
```

This task:
- Removes backup columns (irreversible)
- Should only be run after thorough testing

## 🔑 **Key Management**

### **Encryption Keys Location**
- Stored in Rails credentials (`config/credentials.yml.enc`)
- Encrypted using the master key (`config/master.key`)
- **Never commit the master key to version control**

### **Production Deployment**
```bash
# Set the master key as an environment variable
export RAILS_MASTER_KEY=your_master_key_here

# Or place it in config/master.key on the server
echo "your_master_key_here" > config/master.key
```

### **Key Rotation**
Rails supports key rotation for enhanced security:
```bash
# Generate new encryption keys
rails db:encryption:init

# Add to credentials under 'previous' section for rotation
# Update models to use new keys while maintaining access to old data
```

## 🛡️ **Security Best Practices**

### **Environment Variables**
- Use environment variables for sensitive configuration
- Never hardcode API keys or secrets in code
- Use different keys for different environments

### **Database Security**
- Enable database encryption at rest
- Use SSL/TLS for database connections
- Restrict database access to necessary services only
- Regular database backups with encryption

### **Application Security**
- Keep Rails and dependencies updated
- Use HTTPS in production
- Implement proper authentication and authorization
- Regular security audits and penetration testing

### **Token Management**
- Implement token refresh mechanisms
- Monitor for token usage anomalies
- Revoke compromised tokens immediately
- Use short-lived tokens when possible

## 🔍 **Monitoring & Auditing**

### **Encryption Status Monitoring**
```ruby
# Check if encryption is working
Shop.first.shopify_token # Should return decrypted token
# Raw database value should be encrypted

# Monitor encryption errors
Rails.logger.info "Encryption status: #{Rails.application.credentials.active_record_encryption.present?}"
```

### **Security Logging**
- Log token access attempts
- Monitor for unusual API usage patterns
- Alert on encryption/decryption failures
- Track token refresh events

## ⚠️ **Important Considerations**

### **Backup Strategy**
- Encrypted data requires the same encryption keys to restore
- Store master keys securely and separately from database backups
- Test backup restoration procedures regularly

### **Performance Impact**
- Encryption/decryption adds minimal overhead
- Consider caching decrypted tokens for high-frequency operations
- Monitor application performance after implementation

### **Development Environment**
- Use different encryption keys for development
- Never use production keys in development
- Test encryption migration on development data first

## 🚨 **Emergency Procedures**

### **Key Compromise**
1. Generate new encryption keys immediately
2. Rotate all API tokens
3. Update credentials with new keys
4. Re-encrypt all sensitive data
5. Audit access logs for unauthorized usage

### **Data Recovery**
1. Ensure master key is available
2. Restore database from backup
3. Verify encryption keys match
4. Test token functionality
5. Monitor for any issues

## 📋 **Compliance**

This implementation helps meet various compliance requirements:
- **PCI DSS**: Protects stored authentication data
- **GDPR**: Ensures personal data protection
- **SOC 2**: Demonstrates security controls
- **HIPAA**: Protects sensitive information (if applicable)

## 🔧 **Troubleshooting**

### **Common Issues**

#### **"ActiveRecord::Encryption::Errors::Decryption" Error**
- Check master key is correct
- Verify encryption keys in credentials
- Ensure model has `encrypts` declaration

#### **Tokens Not Working After Migration**
- Verify migration completed successfully
- Check token format and validity
- Test API connections manually

#### **Performance Issues**
- Monitor encryption overhead
- Consider caching strategies
- Optimize database queries

### **Debug Commands**
```bash
# Check encryption configuration
rails runner "puts Rails.application.credentials.active_record_encryption"

# Verify token encryption
rails db:encryption:verify

# Test token functionality
rails runner "puts Shop.first.shopify_token.present?"
```

## 📞 **Support**

For security-related issues:
1. Check this documentation first
2. Review Rails encryption documentation
3. Test in development environment
4. Contact system administrator if needed

**Remember**: Security is an ongoing process, not a one-time implementation. Regular reviews and updates are essential. 