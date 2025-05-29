# README

# Kuralis - AI-Powered E-commerce Platform

**Kuralis** is a sophisticated Ruby on Rails application that serves as an AI-powered multi-platform e-commerce management system. It seamlessly integrates with Shopify and eBay to provide automated product creation, intelligent inventory management, and cross-platform synchronization capabilities.

## 🚀 **Core Features**

### **AI-Powered Product Creation**
- **GPT-4 Vision Integration**: Upload product images and let AI automatically extract product details
- **Smart Category Matching**: AI suggests optimal eBay categories with confidence scoring
- **Item Specifics Validation**: Real-time validation against eBay's category requirements
- **Bulk Processing**: Handle hundreds of images simultaneously with optimized performance
- **Sequential Finalization**: Streamlined workflow for bulk product review and finalization

### **Multi-Platform Integration**
- **Shopify App**: Native Shopify app integration with OAuth authentication
- **eBay API Integration**: Complete eBay marketplace integration with listing management
- **Cross-Platform Sync**: Automated inventory synchronization between platforms
- **Unified Product Management**: Single interface to manage products across all platforms

### **Advanced Inventory Management**
- **Distributed Locking**: Redis-based locking prevents race conditions
- **Real-time Synchronization**: Instant inventory updates across all platforms
- **Automated Reconciliation**: Detects and corrects inventory discrepancies
- **Transaction Tracking**: Complete audit trail of all inventory changes
- **Health Monitoring**: Proactive alerts for low stock and system issues

### **Intelligent Order Processing**
- **Unified Order Management**: Handle orders from both Shopify and eBay
- **Idempotency Protection**: Prevents duplicate order processing
- **Automated Fulfillment**: Streamlined order fulfillment workflows
- **Cross-Platform Updates**: Order status sync across all platforms

## 🏗️ **Architecture Overview**

### **Technology Stack**
- **Framework**: Ruby on Rails 8.0
- **Database**: PostgreSQL with pgvector for AI embeddings
- **Background Jobs**: Sidekiq with Redis
- **AI Integration**: OpenAI GPT-4 Vision API
- **Image Processing**: ImageProcessing with libvips
- **Frontend**: Hotwire (Turbo + Stimulus) with Bootstrap 5
- **File Storage**: Active Storage with AWS S3
- **Deployment**: Docker with Kamal deployment

### **Core Models**

#### **KuralisProduct**
The central product model that unifies products across platforms:
- **Draft System**: AI-created drafts for user review before finalization
- **Multi-platform Linking**: Links to Shopify products and eBay listings
- **Image Management**: Advanced image processing and optimization
- **Validation System**: Conditional validations for drafts vs finalized products

#### **AiProductAnalysis**
Manages AI-powered product analysis:
- **Status Tracking**: Pending → Processing → Completed/Failed
- **Confidence Scoring**: AI confidence levels for categories and item specifics
- **Result Storage**: Structured JSON storage of AI analysis results
- **Draft Creation**: Automatic draft product creation from analysis

#### **Shop**
Multi-tenant shop management:
- **Shopify Integration**: OAuth and webhook management
- **eBay Integration**: API credentials and account linking
- **Settings Management**: Platform-specific configurations
- **Inventory Preferences**: Sync settings and warehouse management

### **Key Services**

#### **AI Services**
- **OpenaiService**: GPT-4 Vision API integration
- **EbayCategoryService**: Intelligent eBay category matching with embeddings
- **ItemSpecificsMapper**: Maps AI suggestions to eBay requirements

#### **Inventory Services**
- **InventoryService**: Core inventory management with distributed locking
- **InventoryReconciliationService**: Detects and corrects discrepancies
- **InventoryMonitoringService**: Health checks and proactive monitoring

#### **Platform Services**
- **Shopify Services**: Product sync, order management, webhook handling
- **eBay Services**: Listing management, order sync, API integration

## 🤖 **AI-Powered Workflow**

### **1. Image Upload & Analysis**
```
User uploads images → AI analysis queued → GPT-4 Vision processes image
→ Extract product details → Match eBay categories → Validate item specifics
→ Create draft product → Real-time UI updates
```

### **2. Smart Category Matching**
- **Two-stage Analysis**: Quick product type detection → Targeted category suggestions
- **Confidence Scoring**: Mathematical confidence calculation based on similarity
- **Fallback Strategies**: Multiple matching approaches for maximum accuracy
- **Real-time Validation**: Live validation against eBay's category requirements

### **3. Enhanced Comic Book Analysis**
- **High-detail Processing**: Uses "high" detail mode for text recognition
- **Critical Field Detection**: Issue numbers, series titles, publishers
- **Condition Assessment**: Visual condition analysis
- **Era Classification**: Automatic comic age determination

## 📊 **Real-time Features**

### **Live Progress Tracking**
- **Turbo Streams**: Real-time updates without page refresh
- **Progress Indicators**: Live count updates and completion notifications
- **Smart Tab Switching**: Automatic navigation to completed drafts
- **Persistent Status**: Sidebar indicators across all pages

### **Performance Optimizations**
- **Image Compression**: Automatic optimization for faster AI processing
- **Lazy Loading**: Optimized image loading with variants
- **Batch Processing**: Intelligent batching for large uploads
- **Caching Strategy**: Multi-level caching for improved performance

## 🔄 **Inventory Management**

### **Distributed Architecture**
```ruby
# Redis-based distributed locking
InventoryService.with_lock(product_id) do
  # Atomic inventory operations
  allocate_inventory(quantity)
  sync_across_platforms
  record_transaction
end
```

### **Cross-Platform Synchronization**
- **Skip Platform Logic**: Prevents infinite sync loops
- **Retry Mechanisms**: Exponential backoff for failed syncs
- **Health Monitoring**: Automated detection of sync issues
- **Reconciliation**: Automatic correction of discrepancies

### **Order Processing Flow**
```
Order received → Idempotency check → Inventory allocation
→ Cross-platform sync → Internal record updates → Fulfillment
```

## 🛠️ **Development Setup**

### **Prerequisites**
- Ruby 3.2+
- PostgreSQL 14+
- Redis 6+
- Node.js 18+
- ImageMagick or libvips

### **Installation**
```bash
# Clone repository
git clone https://github.com/your-org/kuralis.git
cd kuralis

# Install dependencies
bundle install
npm install

# Setup database
rails db:create db:migrate db:seed

# Configure environment variables
cp .env.example .env
# Edit .env with your API keys and configuration

# Start services
redis-server
bundle exec sidekiq
rails server
```

### **Required Environment Variables**
```bash
# OpenAI Integration
OPENAI_API_KEY=your_openai_api_key

# Shopify App Configuration
SHOPIFY_API_KEY=your_shopify_api_key
SHOPIFY_API_SECRET=your_shopify_api_secret

# eBay API Configuration
EBAY_APP_ID=your_ebay_app_id
EBAY_CERT_ID=your_ebay_cert_id
EBAY_DEV_ID=your_ebay_dev_id

# Database
DATABASE_URL=postgresql://username:password@localhost/kuralis_development

# Redis
REDIS_URL=redis://localhost:6379

# AWS S3 (for file storage)
AWS_ACCESS_KEY_ID=your_aws_access_key
AWS_SECRET_ACCESS_KEY=your_aws_secret_key
AWS_REGION=us-east-1
AWS_S3_BUCKET=your-s3-bucket
```

## 🚀 **Deployment**

### **Docker Deployment**
```bash
# Build image
docker build -t kuralis .

# Run with docker-compose
docker-compose up -d
```

### **Kamal Deployment**
```bash
# Deploy to production
kamal deploy
```

### **Production Considerations**
- **Sidekiq Monitoring**: Access `/sidekiq` for job monitoring
- **Health Checks**: Built-in health check endpoint at `/up`
- **Background Jobs**: Ensure Sidekiq workers are running
- **Redis Configuration**: Persistent Redis for job queues and locking
- **File Storage**: Configure AWS S3 for production file storage

## 📈 **Monitoring & Analytics**

### **Built-in Monitoring**
- **Inventory Health Checks**: Automated every 15 minutes
- **Performance Metrics**: Upload speeds, AI analysis times
- **Error Tracking**: Comprehensive error logging and alerts
- **Platform Sync Status**: Real-time sync success/failure tracking

### **Dashboard Features**
- **Inventory Overview**: Stock levels, low inventory alerts
- **AI Analysis Metrics**: Success rates, confidence scores
- **Platform Status**: Integration health and sync status
- **Recent Activity**: Order processing, product updates

## 🔧 **Configuration**

### **AI Analysis Settings**
```ruby
# config/application.rb
config.ai_analysis = {
  max_files_per_batch: 500,
  max_file_size: 10.megabytes,
  image_quality: 85,
  max_image_dimension: 1024
}
```

### **Inventory Management**
```ruby
# config/initializers/inventory.rb
INVENTORY_CONFIG = {
  lock_timeout: 30.seconds,
  redis_lock_timeout: 60.seconds,
  critical_low_inventory: 5,
  warning_low_inventory: 10
}
```

## 🧪 **Testing**

### **Test Suite**
```bash
# Run all tests
rails test

# Run specific test files
rails test test/models/kuralis_product_test.rb
rails test test/jobs/ai_product_analysis_job_test.rb

# Run system tests
rails test:system
```

### **Test Coverage**
- **Model Tests**: Comprehensive model validation and behavior testing
- **Job Tests**: Background job processing and error handling
- **Integration Tests**: API integration and webhook testing
- **System Tests**: End-to-end user workflow testing

## 📚 **API Documentation**

### **Internal APIs**
- **AI Analysis API**: Manage product analysis workflows
- **Inventory API**: Real-time inventory management
- **Product API**: CRUD operations for products
- **Sync API**: Platform synchronization endpoints

### **Webhook Endpoints**
- **Shopify Webhooks**: Product updates, order creation, inventory changes
- **eBay Notifications**: Order updates, listing changes, account notifications

## 🤝 **Contributing**

### **Development Workflow**
1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Submit a pull request

### **Code Standards**
- **Ruby Style**: Follow Rubocop Rails Omakase guidelines
- **Testing**: Maintain test coverage above 90%
- **Documentation**: Update README and inline documentation
- **Security**: Run Brakeman security scans

## 📄 **License**

This project is proprietary software. All rights reserved.

## 🆘 **Support**

### **Documentation**
- **API Docs**: Available at `/docs` when running locally
- **Sidekiq UI**: Monitor background jobs at `/sidekiq`
- **Health Check**: System status at `/up`

### **Troubleshooting**
- **Logs**: Check `log/production.log` for detailed error information
- **Background Jobs**: Monitor Sidekiq for failed jobs
- **Database**: Use `rails console` for data inspection
- **Redis**: Monitor Redis for lock and queue status

---

**Kuralis** represents the future of e-commerce management, combining the power of AI with robust multi-platform integration to streamline product creation and inventory management at scale.
