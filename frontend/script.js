/* ============================================
   SCHEMA REGISTRY FRONTEND - SCRIPT
   Fetch and display schemas from the registry
   ============================================ */

// Configuration
// Override via URL param: ?api=https://your-api-url
const SCHEMA_SERVICE_URL = (() => {
  const params = new URLSearchParams(window.location.search);
  return params.get("api") || "https://schema.folddb.com";
})();
const API_ENDPOINTS = {
  available: `${SCHEMA_SERVICE_URL}/api/schemas/available`,
  health: `${SCHEMA_SERVICE_URL}/api/health`,
};

// State
let allSchemas = [];
let currentFilter = "all";
let currentSchema = null;

// DOM Elements
const elements = {
  loadingContainer: document.getElementById("loadingContainer"),
  errorContainer: document.getElementById("errorContainer"),
  emptyContainer: document.getElementById("emptyContainer"),
  schemasGrid: document.getElementById("schemasGrid"),
  schemaSearch: document.getElementById("schemaSearch"),
  filterButtons: document.querySelectorAll(".filter-btn"),
  retryBtn: document.getElementById("retryBtn"),
  errorMessage: document.getElementById("errorMessage"),

  // Stats
  schemaCount: document.getElementById("schemaCount"),
  totalFields: document.getElementById("totalFields"),
  serviceStatus: document.getElementById("serviceStatus"),

  // Modal
  modalOverlay: document.getElementById("modalOverlay"),
  schemaModal: document.getElementById("schemaModal"),
  modalSchemaName: document.getElementById("modalSchemaName"),
  modalSchemaType: document.getElementById("modalSchemaType"),
  modalBody: document.getElementById("modalBody"),
  modalClose: document.getElementById("modalClose"),
  modalCloseBtn: document.getElementById("modalCloseBtn"),
  copyJsonBtn: document.getElementById("copyJsonBtn"),
};

// Initialize
document.addEventListener("DOMContentLoaded", () => {
  init();
});

async function init() {
  setupEventListeners();
  await loadSchemas();
}

function setupEventListeners() {
  // Search
  elements.schemaSearch.addEventListener("input", debounce(handleSearch, 300));

  // Filter buttons
  elements.filterButtons.forEach((btn) => {
    btn.addEventListener("click", () => handleFilter(btn.dataset.filter));
  });

  // Retry button
  elements.retryBtn.addEventListener("click", loadSchemas);

  // Modal
  elements.modalClose.addEventListener("click", closeModal);
  elements.modalCloseBtn.addEventListener("click", closeModal);
  elements.modalOverlay.addEventListener("click", (e) => {
    if (e.target === elements.modalOverlay) closeModal();
  });
  elements.copyJsonBtn.addEventListener("click", copySchemaJson);

  // Keyboard
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeModal();
  });
}

// API Functions
async function loadSchemas() {
  showLoading();

  try {
    // Check health first
    const healthResponse = await fetch(API_ENDPOINTS.health);
    if (healthResponse.ok) {
      elements.serviceStatus.textContent = "✓ Online";
      elements.serviceStatus.style.color = "#27ca40";
    } else {
      elements.serviceStatus.textContent = "⚠ Degraded";
      elements.serviceStatus.style.color = "#ffbd2e";
    }
  } catch (e) {
    elements.serviceStatus.textContent = "✗ Offline";
    elements.serviceStatus.style.color = "#ff5f56";
  }

  try {
    const response = await fetch(API_ENDPOINTS.available);

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    allSchemas = data.schemas || [];

    // Update stats
    updateStats();

    // Render
    renderSchemas();
  } catch (error) {
    console.error("Failed to load schemas:", error);
    showError(error.message);
  }
}

function updateStats() {
  elements.schemaCount.textContent = allSchemas.length;

  const totalFields = allSchemas.reduce((sum, schema) => {
    const fieldCount = schema.fields?.length || 0;
    const transformCount = schema.transform_fields
      ? Object.keys(schema.transform_fields).length
      : 0;
    return sum + fieldCount + transformCount;
  }, 0);
  elements.totalFields.textContent = totalFields;
}

// UI State Functions
function showLoading() {
  elements.loadingContainer.style.display = "flex";
  elements.errorContainer.style.display = "none";
  elements.emptyContainer.style.display = "none";
  elements.schemasGrid.innerHTML = "";
}

function showError(message) {
  elements.loadingContainer.style.display = "none";
  elements.errorContainer.style.display = "flex";
  elements.emptyContainer.style.display = "none";
  elements.errorMessage.textContent = message;
}

function showEmpty() {
  elements.loadingContainer.style.display = "none";
  elements.errorContainer.style.display = "none";
  elements.emptyContainer.style.display = "flex";
}

function hideAllStates() {
  elements.loadingContainer.style.display = "none";
  elements.errorContainer.style.display = "none";
  elements.emptyContainer.style.display = "none";
}

// Filtering and Search
function handleSearch(e) {
  renderSchemas();
}

function handleFilter(filter) {
  currentFilter = filter;

  // Update button states
  elements.filterButtons.forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.filter === filter);
  });

  renderSchemas();
}

function getFilteredSchemas() {
  const searchTerm = elements.schemaSearch.value.toLowerCase().trim();

  return allSchemas.filter((schema) => {
    // Filter by type
    if (currentFilter !== "all") {
      const schemaType = schema.schema_type || "Single";
      if (schemaType !== currentFilter) return false;
    }

    // Filter by search
    if (searchTerm) {
      const name = (schema.name || "").toLowerCase();
      const descriptiveName = (schema.descriptive_name || "").toLowerCase();
      const fields = (schema.fields || []).join(" ").toLowerCase();
      const transformFields = schema.transform_fields
        ? Object.keys(schema.transform_fields).join(" ").toLowerCase()
        : "";

      const searchable = `${name} ${descriptiveName} ${fields} ${transformFields}`;
      if (!searchable.includes(searchTerm)) return false;
    }

    return true;
  });
}

// Rendering
function renderSchemas() {
  hideAllStates();

  const filteredSchemas = getFilteredSchemas();

  if (filteredSchemas.length === 0) {
    showEmpty();
    return;
  }

  elements.schemasGrid.innerHTML = filteredSchemas
    .map((schema) => createSchemaCard(schema))
    .join("");

  // Attach click handlers
  elements.schemasGrid.querySelectorAll(".schema-card").forEach((card) => {
    card.addEventListener("click", () => {
      const schemaName = card.dataset.schemaName;
      const schema = allSchemas.find((s) => s.name === schemaName);
      if (schema) openModal(schema);
    });
  });
}

function createSchemaCard(schema) {
  const name = schema.name || "Unnamed Schema";
  const schemaType = schema.schema_type || "Single";
  const fields = schema.fields || [];
  const transformFields = schema.transform_fields
    ? Object.keys(schema.transform_fields)
    : [];
  const allFields = [...fields, ...transformFields];
  const topologyHash = schema.topology_hash || "N/A";

  // Display first 4 fields, then show count
  const displayFields = allFields.slice(0, 4);
  const moreCount = allFields.length - displayFields.length;

  return `
    <div class="schema-card" data-schema-name="${escapeHtml(name)}">
      <div class="schema-card-header">
        <h3 class="schema-card-title">${escapeHtml(truncateName(name, 40))}</h3>
        <span class="type-badge ${schemaType}">${schemaType}</span>
      </div>
      
      <div class="schema-card-meta">
        <span class="meta-item">
          <span class="meta-icon">📋</span>
          ${allFields.length} field${allFields.length !== 1 ? "s" : ""}
        </span>
        ${
          schema.key
            ? `
          <span class="meta-item">
            <span class="meta-icon">🔑</span>
            Keyed
          </span>
        `
            : ""
        }
      </div>
      
      ${
        allFields.length > 0
          ? `
        <div class="schema-card-fields">
          ${displayFields.map((f) => `<span class="field-tag">${escapeHtml(f)}</span>`).join("")}
          ${moreCount > 0 ? `<span class="field-tag more">+${moreCount} more</span>` : ""}
        </div>
      `
          : ""
      }
      
      <div class="schema-card-hash">
        <span class="hash-label">hash:</span>
        <span class="hash-value">${escapeHtml(topologyHash.substring(0, 16))}...</span>
      </div>
    </div>
  `;
}

// Modal Functions
function openModal(schema) {
  currentSchema = schema;

  const name = schema.name || "Unnamed Schema";
  const schemaType = schema.schema_type || "Single";

  elements.modalSchemaName.textContent = name;
  elements.modalSchemaType.textContent = schemaType;
  elements.modalSchemaType.className = `type-badge ${schemaType}`;

  elements.modalBody.innerHTML = createModalContent(schema);
  elements.modalOverlay.classList.add("open");
  document.body.style.overflow = "hidden";
}

function closeModal() {
  elements.modalOverlay.classList.remove("open");
  document.body.style.overflow = "";
  currentSchema = null;
}

function createModalContent(schema) {
  const sections = [];

  // Basic Info
  sections.push(`
    <div class="detail-section">
      <h4 class="detail-section-title">Basic Information</h4>
      <div class="detail-info-grid">
        <div class="detail-info-item">
          <div class="detail-info-label">Name</div>
          <div class="detail-info-value">${escapeHtml(schema.name || "N/A")}</div>
        </div>
        ${
          schema.descriptive_name
            ? `
          <div class="detail-info-item">
            <div class="detail-info-label">Descriptive Name</div>
            <div class="detail-info-value">${escapeHtml(schema.descriptive_name)}</div>
          </div>
        `
            : ""
        }
        <div class="detail-info-item">
          <div class="detail-info-label">Type</div>
          <div class="detail-info-value">${escapeHtml(schema.schema_type || "Single")}</div>
        </div>
        <div class="detail-info-item">
          <div class="detail-info-label">Topology Hash</div>
          <div class="detail-info-value">${escapeHtml(schema.topology_hash || "N/A")}</div>
        </div>
      </div>
    </div>
  `);

  // Key Configuration
  if (schema.key) {
    sections.push(`
      <div class="detail-section">
        <h4 class="detail-section-title">Key Configuration</h4>
        <div class="detail-info-grid">
          ${
            schema.key.hash_field
              ? `
            <div class="detail-info-item">
              <div class="detail-info-label">Hash Field</div>
              <div class="detail-info-value">${escapeHtml(schema.key.hash_field)}</div>
            </div>
          `
              : ""
          }
          ${
            schema.key.range_field
              ? `
            <div class="detail-info-item">
              <div class="detail-info-label">Range Field</div>
              <div class="detail-info-value">${escapeHtml(schema.key.range_field)}</div>
            </div>
          `
              : ""
          }
        </div>
      </div>
    `);
  }

  // Fields
  const fields = schema.fields || [];
  const transformFields = schema.transform_fields || {};
  const fieldTopologies = schema.field_topologies || {};

  if (fields.length > 0 || Object.keys(transformFields).length > 0) {
    sections.push(`
      <div class="detail-section">
        <h4 class="detail-section-title">Fields (${fields.length + Object.keys(transformFields).length})</h4>
        <div class="fields-list">
          ${fields
            .map((fieldName) => {
              const topology = fieldTopologies[fieldName];
              return `
              <div class="field-item">
                <div class="field-item-header">
                  <span class="field-item-name">${escapeHtml(fieldName)}</span>
                  <span class="field-item-type">data field</span>
                </div>
                ${
                  topology
                    ? `
                  <div class="field-item-topology">${escapeHtml(formatTopology(topology))}</div>
                `
                    : ""
                }
              </div>
            `;
            })
            .join("")}
          ${Object.entries(transformFields)
            .map(([fieldName, expression]) => {
              const topology = fieldTopologies[fieldName];
              return `
              <div class="field-item">
                <div class="field-item-header">
                  <span class="field-item-name">${escapeHtml(fieldName)}</span>
                  <span class="field-item-type">transform</span>
                </div>
                <div class="field-item-topology">${escapeHtml(expression)}</div>
              </div>
            `;
            })
            .join("")}
        </div>
      </div>
    `);
  }

  // Raw JSON
  sections.push(`
    <div class="detail-section">
      <h4 class="detail-section-title">Raw JSON</h4>
      <div class="json-view">
        <pre>${escapeHtml(JSON.stringify(schema, null, 2))}</pre>
      </div>
    </div>
  `);

  return sections.join("");
}

function formatTopology(topology) {
  if (!topology) return "N/A";

  // Simplified topology display
  if (topology.root) {
    return formatTopologyNode(topology.root);
  }
  return JSON.stringify(topology, null, 2);
}

function formatTopologyNode(node) {
  if (!node) return "unknown";

  if (node.Primitive) {
    return node.Primitive.primitive_type || "Primitive";
  }
  if (node.Array) {
    return `Array<${formatTopologyNode(node.Array.value)}>`;
  }
  if (node.Object) {
    const fields = Object.keys(node.Object.fields || {});
    if (fields.length <= 3) {
      return `{ ${fields.join(", ")} }`;
    }
    return `{ ${fields.slice(0, 3).join(", ")}, ... }`;
  }
  if (node === "Any") {
    return "Any";
  }

  return JSON.stringify(node);
}

async function copySchemaJson() {
  if (!currentSchema) return;

  try {
    await navigator.clipboard.writeText(JSON.stringify(currentSchema, null, 2));
    showToast("Copied to clipboard!", "success");
  } catch (error) {
    console.error("Failed to copy:", error);
    showToast("Failed to copy", "error");
  }
}

// Utility Functions
function escapeHtml(str) {
  if (!str) return "";
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

function truncateName(name, maxLength) {
  if (!name || name.length <= maxLength) return name;
  return name.substring(0, maxLength) + "...";
}

function debounce(func, wait) {
  let timeout;
  return function executedFunction(...args) {
    const later = () => {
      clearTimeout(timeout);
      func(...args);
    };
    clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

function showToast(message, type = "info") {
  // Remove existing toast
  const existingToast = document.querySelector(".toast");
  if (existingToast) existingToast.remove();

  const toast = document.createElement("div");
  toast.className = `toast ${type}`;
  toast.textContent = message;
  document.body.appendChild(toast);

  // Trigger animation
  requestAnimationFrame(() => {
    toast.classList.add("show");
  });

  // Remove after delay
  setTimeout(() => {
    toast.classList.remove("show");
    setTimeout(() => toast.remove(), 300);
  }, 3000);
}

// Mobile menu toggle
document.getElementById("mobileToggle")?.addEventListener("click", () => {
  const navLinks = document.querySelector(".nav-links");
  navLinks.style.display = navLinks.style.display === "flex" ? "none" : "flex";
});
