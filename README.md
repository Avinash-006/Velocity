# Velocity - AI Image Generation App

Velocity is a streamlined AI image generation application powered by Stable Diffusion, focused on creating stunning images from text prompts.

## Features

### 🎨 Image Generation
- **Text-to-Image**: Create images from detailed text descriptions
- **Stable Diffusion**: Powered by advanced AI image generation models
- **Real-time Generation**: See your images come to life instantly
- **High Quality Output**: Generate detailed, high-resolution images

### 📦 Model Management
- **Download Models**: Access and download Stable Diffusion models
- **Model Library**: Browse available models with descriptions and sizes
- **Progress Tracking**: Monitor download progress in real-time
- **Storage Management**: View and delete downloaded models
- **Model Selection**: Choose which model to use for generation

## How to Use

### Generating Images
1. Enter your image description in the prompt field
2. Example: "a beautiful sunset over mountains, photorealistic, 4k"
3. Tap "Generate Image"
4. View your generated image instantly

### Managing Models
1. Go to the Model Management tab
2. Browse available Stable Diffusion models
3. Download models you want to use locally
4. Select your preferred model for generation
5. Manage storage by deleting unused models

## Technical Details
- **Framework**: SwiftUI
- **Image Generation**: Stable Diffusion (simulated for demo)
- **Storage**: Local file system for model management
- **UI**: Modern, intuitive interface with focus on image creation

## Requirements
- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

## Setup
1. Clone the repository
2. Open `Velocity.xcodeproj` in Xcode
3. Build and run the project

## Notes
- Model downloads are simulated for the demo version
- To use click on open link in model management, Download the model unzip and place it in StableDiffusionModels Folder in Velocity
- The initial model inference might be slow wait for 2-4 minutes for the first image to generate as the model needs to be loaded into the memory the later images will be faster

  ## Benchmarks

| Device | Prompt | Steps | Guidance | Model | Time | Generated Image |
|--------|--------|-------|----------|-------|------|-----------------|
| iPad A16 | Car | 25 | 5.5 | Epicrealism_Se2_Bit6 (6-Bit 512x512) | 18.7s | ![Car Generation](https://drive.google.com/uc?export=view&id=1_iEFEl67qN1R4Rhkc0Xz7YNZOgkGDJk9) |
| iPad A16 | Ultra-realistic cinematic night scene: a lone character in a neon-lit cyberpunk alley during rain, wet reflective streets, glowing signs, soft volumetric fog, shallow depth of field, sharp facial focus, realistic skin texture, cinematic lighting, 85mm lens look, HDR, film grain, 8k detail. | 40 | 5.0 | Epicrealism_Se2_Bit6 (6-Bit 512x512) | 27.89s | ![Cyberpunk Scene](https://drive.google.com/uc?export=view&id=13_JFcGm5TnsrNC49sDRF2OuI2KnjMhKR) |

## Future Fixes
- Proper Download and Extract Features for models
- Improved Stability
- Proper Upscaling
- Proper Latent View
- Optimization

## Tips for Best Results
- Be specific and detailed in your prompts
- Include style keywords like "photorealistic", "oil painting", "digital art"
- Mention quality enhancers like "4k", "highly detailed", "trending on artstation"
- Experiment with different models for varied artistic styles
