# Schema Registry Frontend

A web frontend for browsing the FoldDB Global Schema Registry.

## Overview

This is a static web application that displays schemas registered in the global FoldDB schema service at `https://schema.folddb.com`.

## Features

- **Schema List**: View all registered schemas in a responsive grid
- **Search & Filter**: Search by name/fields and filter by schema type (Single, Range, HashRange)
- **Schema Details**: Click to view full schema definition including fields, topologies, and key configuration
- **Copy JSON**: Export schema definitions as JSON
- **Responsive Design**: Works on desktop and mobile

## Local Development

Start a local server:

```bash
cd schema_registry_frontend
python3 -m http.server 8080
```

Then open http://localhost:8080 in your browser.

## Deployment

The site is configured for Vercel deployment:

1. Connect the repository to Vercel
2. Vercel will automatically detect the static site configuration
3. Deploy to your domain (e.g., `schemas.folddb.com`)

## API

The frontend connects to the Schema Service API:

| Endpoint                     | Description                          |
| ---------------------------- | ------------------------------------ |
| `GET /api/schemas/available` | Returns all schemas with definitions |
| `GET /api/health`            | Health check endpoint                |

Base URL: `https://schema.folddb.com`

## Design

The frontend uses the FoldDB premium developer design system:

- **Colors**: Dark theme with indigo/purple/cyan accents
- **Typography**: Inter for UI, JetBrains Mono for code
- **Effects**: Animated gradient orbs, glass-morphism cards

## License

MIT / Apache 2.0
