# Velocity - AI Chat App with Image Generation

Velocity is a comprehensive AI chat application that combines text-based conversations with image generation capabilities using Stable Diffusion.

## Features

### 🗨️ Chat Tab
- **AI Conversations**: Chat with Gemini AI for text-based interactions
- **Voice Input**: Use speech-to-text for hands-free messaging
- **File Attachments**: Upload and share files, images, and documents
- **Image Generation**: Type "generate image [prompt]" to create images using Stable Diffusion
- **Chat History**: Save and manage multiple conversation threads

### 🎨 Playground Tab
- **Drawing Canvas**: Draw with finger or Apple Pencil on a responsive canvas
- **Image Generation**: Convert your drawings into AI-generated images
- **Real-time Preview**: See your generated images immediately
- **Clear Canvas**: Reset your drawing area with one tap

### 📦 Model Management Tab
- **Download Models**: Access and download Stable Diffusion models
- **Model Library**: Browse available models with descriptions and sizes
- **Progress Tracking**: Monitor download progress in real-time
- **Storage Management**: View and delete downloaded models

## How to Use

### Image Generation in Chat
1. Type "generate image" followed by your description
2. Example: "generate image a beautiful sunset over mountains"
3. The AI will create and display the generated image

### Drawing and Generation in Playground
1. Switch to the Playground tab
2. Draw your sketch using finger or Apple Pencil
3. Tap "Generate Image" to convert your drawing
4. View the generated result

### Model Management
1. Go to the Model Management tab
2. Browse available Stable Diffusion models
3. Download models you want to use locally
4. Manage your downloaded models

## Technical Details

- **Framework**: SwiftUI
- **AI Service**: Google Gemini for text generation
- **Image Generation**: Stable Diffusion (simulated for demo)
- **Drawing**: PencilKit for canvas functionality
- **Storage**: Local file system for model management

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

## Setup

1. Clone the repository
2. Open `Velocity.xcodeproj` in Xcode
3. Add your Gemini API key to `Info.plist` as `GEMINI_API_KEY`
4. Build and run the project

## Notes

- The current implementation uses simulated Stable Diffusion for demonstration
- For production use, integrate with actual Stable Diffusion APIs or local models
- Model downloads are simulated for the demo version
